import Clocks
import Combine
import Dependencies
import Foundation
import SwiftUI

enum OtherPRError: LocalizedError {
    case invalidURL
    case alreadyAdded
    case alreadyTracked
    case notFound

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid GitHub PR URL. Expected format: https://github.com/owner/repo/pull/123"
        case .alreadyAdded: return "This PR is already in Other PRs"
        case .alreadyTracked: return "This PR is already in your authored or review list"
        case .notFound: return "PR not found or not accessible"
        }
    }
}

@MainActor
class PRMonitorViewModel: ObservableObject {
    @Published var pullRequests: [PullRequest] = []
    @Published var otherPullRequests: [PullRequest] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var lastRefreshTime: Date?
    @Published var isGHAvailable = true
    @Published var showWarningIcon = false
    @Published private(set) var copiedPRID: String? = nil

    @Dependency(UserDefaultsStore.self) private var defaults
    @Dependency(WatchlistServiceKey.self) private var watchlistService
    @Dependency(NotificationServiceKey.self) private var notificationService
    @Dependency(OtherPRsServiceKey.self) private var otherPRsService
    @Dependency(CustomNamesServiceKey.self) private var customNamesService
    @Dependency(PRCacheServiceKey.self) private var cacheService
    @Dependency(GitHubServiceKey.self) private var githubService
    @Dependency(PasteboardClientKey.self) private var pasteboard
    @Dependency(\.continuousClock) private var clock

    private let isDemoMode: Bool
    /// How long a stack resolution is reused before the lookup repeats. Instance
    /// state so tests can inject a tiny interval.
    private let stackResolutionTTL: TimeInterval

    private var refreshTimer: Timer?
    private var defaultsObserver: AnyCancellable?
    private var unsortedPullRequests: [PullRequest] = []
    private var copiedPRLinkTask: Task<Void, Never>?
    /// Stack ids already notified ready, seeded from preferences at launch so a
    /// relaunch does not notify again for a stack that is still ready.
    private var readyStackIDs: Set<String> = []
    /// Completed stacks for this session, keyed by stack id, so a poll that
    /// still shows the same visible parts reuses the earlier lookup.
    private var stackResolutionCache: [String: StackResolutionCacheEntry] = [:]
    /// Stack parts removed this session, by PR id. Completion would otherwise
    /// re-add them as companions for as long as a sibling anchor stays in a list.
    private var removedStackPartIDs: Set<String> = []
    /// Stack parts currently in the lists only because completion added them,
    /// by PR id. Rebuilt on every refresh from the parts actually appended, so
    /// `isStackCompanion(_:)` can mark rows the user did not ask to track.
    private var stackCompanionIDs: Set<String> = []

    /// Stack blocks the user collapsed, by stack id. Session state: a freshly
    /// launched app starts with every block expanded.
    @Published private(set) var collapsedStackIDs: Set<String> = []

    var copyClearTask: Task<Void, Never>? { copiedPRLinkTask }

    var selectedRepository: String {
        get { defaults.string(forKey: PreferenceKeys.selectedRepository) ?? "All Repositories" }
        set {
            defaults.set(newValue, forKey: PreferenceKeys.selectedRepository)
            objectWillChange.send()
        }
    }

    var selectedRepositoryBinding: Binding<String> {
        Binding(
            get: { self.selectedRepository },
            set: { self.selectedRepository = $0 }
        )
    }

    var refreshInterval: Int {
        defaults.object(forKey: PreferenceKeys.refreshInterval) as? Int ?? Constants.defaultRefreshInterval
    }

    private var sortNonSuccessFirst: Bool {
        defaults.bool(forKey: PreferenceKeys.sortNonSuccessFirst)
    }

    private var showReviewPRs: Bool {
        defaults.object(forKey: PreferenceKeys.showReviewPRs) as? Bool ?? true
    }

    private var enableInactiveBranchDetection: Bool {
        defaults.bool(forKey: PreferenceKeys.enableInactiveBranchDetection)
    }

    private var hideInactivePRs: Bool {
        defaults.bool(forKey: PreferenceKeys.hideInactivePRs)
    }

    private var inactiveBranchThresholdDays: Int {
        defaults.object(forKey: PreferenceKeys.inactiveBranchThresholdDays) as? Int ?? Constants.defaultInactiveBranchThreshold
    }

    var availableRepositories: [String] {
        let mainRepos = Set(unsortedPullRequests.map { $0.repository.nameWithOwner })
        let otherRepos = Set(otherPullRequests.map { $0.repository.nameWithOwner })
        return mainRepos.union(otherRepos).sorted()
    }

    var reposWithIssues: Set<String> {
        let allPRs = unsortedPullRequests + otherPullRequests
        let visiblePRs = hideInactivePRs ? allPRs.filter { !isInactiveByAge($0) } : allPRs
        return Set(visiblePRs.compactMap { pr -> String? in
            let badBuild = pr.buildStatus == .failure || pr.buildStatus == .error
                || pr.buildStatus == .conflict || pr.buildStatus == .notStarted
                || pr.buildStatus == .inactive
            guard badBuild || pr.reviewDecision == .changesRequested else { return nil }
            return pr.repository.nameWithOwner
        })
    }

    /// Rows for a section: unstacked PRs as-is, each stack as one block (header plus
    /// its parts in merge order, part 1 first so the base sits at the top).
    func sectionRows(for type: PRType) -> [PRListRow] {
        PRStackOrdering.rows(from: sectionPRs(for: type), collapsedStackIDs: collapsedStackIDs)
    }

    var authoredPRs: [PullRequest] {
        PRStackOrdering.rows(from: sectionPRs(for: .authored)).compactMap(\.pr)
    }

    var reviewPRs: [PullRequest] {
        PRStackOrdering.rows(from: sectionPRs(for: .reviewing)).compactMap(\.pr)
    }

    var filteredOtherPRs: [PullRequest] {
        PRStackOrdering.rows(from: sectionPRs(for: .other)).compactMap(\.pr)
    }

    private func sectionPRs(for type: PRType) -> [PullRequest] {
        switch type {
        case .reviewing:
            guard showReviewPRs else { return [] }
            return pullRequests.filter { $0.type == .reviewing && matchesSelectedRepository($0) }
        case .authored:
            let prs = pullRequests.filter { $0.type == .authored && matchesSelectedRepository($0) }
            return hideInactivePRs ? prs.filter { !isInactiveByAge($0) } : prs
        case .other:
            let prs = otherPullRequests.filter(matchesSelectedRepository)
            return hideInactivePRs ? prs.filter { !isInactiveByAge($0) } : prs
        }
    }

    private func matchesSelectedRepository(_ pr: PullRequest) -> Bool {
        selectedRepository == "All Repositories" || pr.repository.nameWithOwner == selectedRepository
    }

    private func isInactiveByAge(_ pr: PullRequest) -> Bool {
        guard enableInactiveBranchDetection else { return pr.buildStatus == .inactive }
        let daysSinceUpdate = Date().timeIntervalSince(pr.updatedAt) / Constants.secondsPerDay
        return daysSinceUpdate >= Double(inactiveBranchThresholdDays)
    }

    init(
        isDemoMode: Bool = false,
        stackResolutionTTL: TimeInterval = Constants.stackResolutionRevalidationInterval
    ) {
        self.isDemoMode = isDemoMode
        self.stackResolutionTTL = stackResolutionTTL
        readyStackIDs = loadNotifiedReadyStackIDs()
        restoreFromCache()
        setupNotifications()
        startPolling()
        observeDefaultsChanges()
    }

    deinit {
        MainActor.assumeIsolated {
            refreshTimer?.invalidate()
            defaultsObserver?.cancel()
        }
    }

    private func restoreFromCache() {
        let cached = cacheService.loadMainPRs()
        if !cached.isEmpty {
            unsortedPullRequests = cached.map {
                var pr = $0; pr.isWatched = watchlistService.isWatched(pr); return pr
            }
            applySorting()
        }
        otherPullRequests = cacheService.loadOtherPRs().map {
            var pr = $0; pr.isWatched = watchlistService.isWatched(pr); return pr
        }
    }

    private func observeDefaultsChanges() {
        let underlying = defaults.underlyingDefaults
        defaultsObserver = underlying
            .publisher(for: \.sortNonSuccessFirstDisplay)
            .merge(with: underlying.publisher(for: \.showReviewPRsDisplay))
            .merge(with: underlying.publisher(for: \.hideInactivePRsDisplay))
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
                self?.applySorting()
            }
    }

    func startPolling() {
        refreshTimer?.invalidate()

        refreshTimer = Timer.scheduledTimer(
            withTimeInterval: TimeInterval(refreshInterval),
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
            }
        }

        Task {
            await refresh()
        }
    }

    func stopPolling() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func updateRefreshInterval(_ interval: Int) {
        defaults.set(interval, forKey: PreferenceKeys.refreshInterval)
        startPolling()
    }

    func refresh() async {
        isLoading = true
        errorMessage = nil

        async let mainFetchTask = githubService.fetchAllOpenPRs(
            enableInactiveDetection: enableInactiveBranchDetection,
            inactiveThresholdDays: inactiveBranchThresholdDays,
            isDemoMode: isDemoMode
        )
        async let otherFetchTask = fetchAllOtherPRs()

        do {
            let fetchResult = try await mainFetchTask
            let fetchedOther = await otherFetchTask
            let fetchedPRs = fetchResult.pullRequests

            let otherIDs = Set(fetchedOther.map { $0.id })
            let dedupedPRs = fetchedPRs.filter { !otherIDs.contains($0.id) }

            let (mainPRs, otherPRs) = await completeStacks(mainPRs: dedupedPRs, otherPRs: fetchedOther)

            let completed = watchlistService.checkForCompletions(currentPRs: mainPRs + otherPRs)

            for pr in completed {
                notificationService.notifyBuildComplete(pr: pr, status: pr.buildStatus)
            }

            unsortedPullRequests = applyCustomNames(mainPRs.map { pr in
                var updated = pr
                updated.isWatched = watchlistService.isWatched(pr)
                return updated
            })

            otherPullRequests = applyCustomNames(otherPRs.map { pr in
                var updated = pr
                updated.isWatched = watchlistService.isWatched(pr)
                return updated
            })

            let activeIDs = Set((mainPRs + otherPRs).map { $0.id })
            customNamesService.pruneStale(keeping: activeIDs)

            applySorting()
            // A partial fetch omits whole stacks when one host's search fails, and
            // readinessTransitions rebuilds the ready set from only the PRs present,
            // so a stack missing here would be wrongly read as "no longer ready" and
            // re-notify on the next full refresh. Defer the evaluation to the next
            // full refresh instead.
            if !fetchResult.isPartial {
                notifyReadyStacks(allPRs: mainPRs + otherPRs)
            }

            if !fetchResult.isPartial &&
                selectedRepository != "All Repositories" &&
                !unsortedPullRequests.contains(where: { $0.repository.nameWithOwner == selectedRepository }) &&
                !otherPullRequests.contains(where: { $0.repository.nameWithOwner == selectedRepository }) {
                selectedRepository = "All Repositories"
            }

            cacheService.save(mainPRs: unsortedPullRequests, otherPRs: otherPullRequests)

            lastRefreshTime = Date()
            isGHAvailable = true

        } catch let error as GitHubError {
            print("GitHubError: \(error)")
            errorMessage = error.localizedDescription
            if error == .notInstalled || error == .notAuthenticated {
                isGHAvailable = false
            }
            let fetchedOther = await otherFetchTask
            otherPullRequests = applyCustomNames(fetchedOther.map { pr in
                var updated = pr
                updated.isWatched = watchlistService.isWatched(pr)
                return updated
            })
        } catch let error as ShellError {
            print("ShellError: \(error)")
            errorMessage = error.localizedDescription
            let fetchedOther = await otherFetchTask
            otherPullRequests = applyCustomNames(fetchedOther.map { pr in
                var updated = pr
                updated.isWatched = watchlistService.isWatched(pr)
                return updated
            })
        } catch let error as DecodingError {
            print("DecodingError: \(error)")
            errorMessage = "Failed to parse GitHub data. Please try again."
            let fetchedOther = await otherFetchTask
            otherPullRequests = applyCustomNames(fetchedOther.map { pr in
                var updated = pr
                updated.isWatched = watchlistService.isWatched(pr)
                return updated
            })
        } catch {
            print("Unknown error: \(error)")
            errorMessage = "An unexpected error occurred: \(error.localizedDescription)"
            let fetchedOther = await otherFetchTask
            otherPullRequests = applyCustomNames(fetchedOther.map { pr in
                var updated = pr
                updated.isWatched = watchlistService.isWatched(pr)
                return updated
            })
        }

        isLoading = false
    }

    private func fetchAllOtherPRs() async -> [PullRequest] {
        let ids = otherPRsService.all()
        var results: [PullRequest] = []
        var staleIDs: [OtherPRIdentifier] = []
        for id in ids {
            do {
                if let pr = try await githubService.fetchOtherPR(
                    id,
                    enableInactiveDetection: enableInactiveBranchDetection,
                    inactiveThresholdDays: inactiveBranchThresholdDays
                ) {
                    results.append(pr)
                } else {
                    staleIDs.append(id)
                }
            } catch {
                print("Transient error fetching Other PR \(id.owner)/\(id.repo)#\(id.number): \(error)")
            }
        }
        for id in staleIDs {
            otherPRsService.remove(id)
            customNamesService.removeName(for: "\(id.owner)/\(id.repo)#\(id.number)")
        }
        return results
    }

    /// One stack's completion lookup, kept for the session so a poll that still
    /// shows the same visible parts reuses it instead of repeating the lookup.
    private struct StackResolutionCacheEntry {
        /// The PR numbers visible in the fetch when the stack was resolved. A
        /// poll showing different numbers invalidates the entry: the stack moved.
        let visibleNumbers: Set<Int>
        /// The open parts the lookup returned that were not visible then.
        let companionParts: [PullRequest]
        /// Positions whose pull request had already merged.
        let mergedPositions: [Int]
        /// When the stack was resolved, for the revalidation interval.
        let resolvedAt: Date
    }

    /// Fetches the parts of any incomplete stack so a stack renders as a whole even
    /// when only one of its PRs matched the user's searches. Companions join the
    /// section of the stack's first anchor and share its type, and are marked as
    /// companions (`isStackCompanion`) so their rows can show they are someone
    /// else's PR rather than something from the user's own lists.
    ///
    /// Resolutions are cached per stack for the session: while the fetch keeps
    /// showing the same visible parts and the revalidation interval has not
    /// elapsed, the earlier lookup is reused instead of refetched. Parts the user
    /// removed this session are never re-added.
    private func completeStacks(
        mainPRs: [PullRequest],
        otherPRs: [PullRequest]
    ) async -> (main: [PullRequest], other: [PullRequest]) {
        guard !isDemoMode else { return (mainPRs, otherPRs) }

        // Collected locally and published once at the end, so the marks on the
        // still-displayed lists never flicker off while this function is
        // suspended on network awaits. Rebuilt fresh every call from the parts
        // appended below, so a part that stops being a companion (it matched a
        // search, merged, or closed) loses its marking on the same refresh.
        var companionIDs: Set<String> = []

        let knownIDs = Set((mainPRs + otherPRs).map(\.id))
        var knownNumbers: [String: Set<Int>] = [:]
        for pr in mainPRs + otherPRs {
            guard let stack = pr.stack else { continue }
            knownNumbers[stack.id, default: []].insert(pr.number)
        }

        var main = mainPRs
        var other = otherPRs
        var visitedStacks: Set<String> = []

        for anchor in mainPRs + otherPRs {
            guard let stack = anchor.stack,
                  visitedStacks.insert(stack.id).inserted,
                  let numbers = knownNumbers[stack.id],
                  numbers.count < stack.size else { continue }

            let completion: StackCompletion
            if let cached = stackResolutionCache[stack.id],
               cached.visibleNumbers == numbers,
               Date().timeIntervalSince(cached.resolvedAt) < stackResolutionTTL {
                // The fetch shows the same parts as when this stack was resolved,
                // so reuse the earlier lookup instead of another round trip.
                completion = StackCompletion(
                    missingParts: cached.companionParts,
                    mergedPositions: cached.mergedPositions
                )
            } else {
                // A nil completion means the lookup failed; nothing is cached so
                // the next poll retries it.
                guard let resolved = await missingParts(for: anchor, stack: stack, knownNumbers: numbers) else {
                    continue
                }
                completion = resolved
                stackResolutionCache[stack.id] = StackResolutionCacheEntry(
                    visibleNumbers: numbers,
                    companionParts: resolved.missingParts,
                    mergedPositions: resolved.mergedPositions,
                    resolvedAt: Date()
                )
            }

            // Exclusions are stored lowercased (see removeOtherPR), so compare the
            // companion's id lowercased as well.
            let parts = completion.missingParts.filter {
                !knownIDs.contains($0.id) && !removedStackPartIDs.contains($0.id.lowercased())
            }
            companionIDs.formUnion(parts.map(\.id))

            if mainPRs.contains(where: { $0.stack?.id == stack.id }) {
                main.append(contentsOf: parts)
            } else {
                other.append(contentsOf: parts)
            }

            // Record the merged positions on every part of this stack, so readiness
            // and the header can account for rows GitHub no longer returns.
            for index in main.indices where main[index].stack?.id == stack.id {
                main[index].stack?.mergedPositions = completion.mergedPositions
            }
            for index in other.indices where other[index].stack?.id == stack.id {
                other[index].stack?.mergedPositions = completion.mergedPositions
            }
        }

        // Publish the rebuilt companion marks in one step, after every network
        // await in this function has resolved.
        stackCompanionIDs = companionIDs
        return (main, other)
    }

    /// Resolves the missing parts of a stack, or nil when the lookup failed. A
    /// successful empty result is still a result: it means the stack has no open
    /// parts beyond the visible ones.
    private func missingParts(
        for anchor: PullRequest,
        stack: PRStackInfo,
        knownNumbers: Set<Int>
    ) async -> StackCompletion? {
        let components = anchor.repository.nameWithOwner.split(separator: "/")
        guard components.count == 2 else { return .empty }

        do {
            return try await githubService.fetchMissingStackParts(
                stackID: stack.id,
                host: anchor.host,
                owner: String(components[0]),
                repo: String(components[1]),
                knownNumbers: knownNumbers,
                type: anchor.type,
                enableInactiveDetection: enableInactiveBranchDetection,
                inactiveThresholdDays: inactiveBranchThresholdDays
            )
        } catch {
            // Completing a stack is best-effort; a failure leaves the stack
            // partial and is retried on the next poll.
            print("Transient error completing stack #\(stack.number): \(error)")
            return nil
        }
    }

    private func applySorting() {
        let authored = unsortedPullRequests.filter { $0.type == .authored }
        let review = unsortedPullRequests.filter { $0.type == .reviewing }

        let sortedAuthored = sortNonSuccessFirst ? sort(authored) : authored
        let sortedReview = sortNonSuccessFirst ? sort(review) : review

        let newPullRequests = sortedReview + sortedAuthored

        if newPullRequests != pullRequests {
            pullRequests = newPullRequests
        }

        var allDisplayed = newPullRequests + otherPullRequests
        if hideInactivePRs {
            allDisplayed = allDisplayed.filter { !isInactiveByAge($0) }
        }
        let hasBadStatus = allDisplayed.contains { pr in
            let badBuild = pr.buildStatus == .failure || pr.buildStatus == .error
                || pr.buildStatus == .conflict || pr.buildStatus == .notStarted
                || pr.buildStatus == .inactive
            return badBuild || pr.reviewDecision == .changesRequested
        }
        let hasReviewPRs = newPullRequests.contains { pr in
            pr.type == .reviewing
        }
        showWarningIcon = hasBadStatus || hasReviewPRs
    }

    func addOtherPR(urlString: String) async throws {
        guard let id = GitHubService.parsePRURL(urlString) else {
            throw OtherPRError.invalidURL
        }
        guard !otherPRsService.contains(id) else {
            throw OtherPRError.alreadyAdded
        }
        let normalizedRepo = "\(id.owner)/\(id.repo)".lowercased()
        guard !unsortedPullRequests.contains(where: { pr in
            pr.number == id.number && pr.repository.nameWithOwner.lowercased() == normalizedRepo
        }) else {
            throw OtherPRError.alreadyTracked
        }
        guard let pr = try await githubService.fetchOtherPR(
            id,
            enableInactiveDetection: enableInactiveBranchDetection,
            inactiveThresholdDays: inactiveBranchThresholdDays
        ) else {
            throw OtherPRError.notFound
        }
        otherPRsService.add(id)
        // Re-adding a part revokes the session exclusion an earlier removal
        // recorded, so stack completion is not permanently blocked for it.
        removedStackPartIDs.remove(pr.id.lowercased())
        var updated = pr
        updated.isWatched = watchlistService.isWatched(pr)
        updated.customName = customNamesService.name(for: pr.id)
        otherPullRequests.append(updated)
        unsortedPullRequests.removeAll { $0.id == pr.id }
        pullRequests.removeAll { $0.id == pr.id }
        applySorting()
    }

    /// True when the user pinned this PR, as opposed to a stack companion that is
    /// only in the list because another part of its stack is pinned.
    func isPinnedPR(_ pr: PullRequest) -> Bool {
        guard let id = otherPRIdentifier(for: pr) else { return false }
        return otherPRsService.contains(id)
    }

    /// True when this PR is a stack companion: a part the completion lookup
    /// added because a sibling anchored a stack in the user's lists, not
    /// something the user tracks themselves. Pinned PRs win: a part the user
    /// added by URL is theirs, not a companion.
    func isStackCompanion(_ pr: PullRequest) -> Bool {
        stackCompanionIDs.contains(pr.id) && !isPinnedPR(pr)
    }

    private func otherPRIdentifier(for pr: PullRequest) -> OtherPRIdentifier? {
        let parts = pr.repository.nameWithOwner.split(separator: "/")
        guard parts.count == 2 else { return nil }
        return OtherPRIdentifier(
            host: pr.host,
            owner: String(parts[0]),
            repo: String(parts[1]),
            number: pr.number
        )
    }

    func removeOtherPR(_ pr: PullRequest) {
        guard let id = otherPRIdentifier(for: pr) else { return }
        otherPRsService.remove(id)
        customNamesService.removeName(for: pr.id)
        // Only stacked parts can reappear once their pin is gone: completion
        // re-adds them as companions while a sibling anchor remains in a list.
        // Non-stacked PRs stay removed on their own, so they need no exclusion.
        // Exclusions are lowercased because a pinned part's id casing comes from
        // the URL the user typed, while completion rebuilds companions with the
        // anchor's API-canonical casing.
        if pr.stack != nil {
            removedStackPartIDs.insert(pr.id.lowercased())
        }
        otherPullRequests.removeAll { $0.id == pr.id }
        applySorting()
        if selectedRepository != "All Repositories" &&
            !unsortedPullRequests.contains(where: { $0.repository.nameWithOwner == selectedRepository }) &&
            !otherPullRequests.contains(where: { $0.repository.nameWithOwner == selectedRepository }) {
            selectedRepository = "All Repositories"
        }
    }

    private func applyCustomNames(_ prs: [PullRequest]) -> [PullRequest] {
        prs.map { pr in
            var updated = pr
            updated.customName = customNamesService.name(for: pr.id)
            return updated
        }
    }

    func renamePR(_ pr: PullRequest, to name: String?) {
        if let name, !name.isEmpty {
            customNamesService.setName(name, for: pr.id)
        } else {
            customNamesService.removeName(for: pr.id)
        }
        unsortedPullRequests = applyCustomNames(unsortedPullRequests)
        pullRequests = applyCustomNames(pullRequests)
        otherPullRequests = applyCustomNames(otherPullRequests)
    }

    private func sort(_ prs: [PullRequest]) -> [PullRequest] {
        prs.sorted { pr1, pr2 in
            if pr1.isMergeBlocked != pr2.isMergeBlocked {
                return pr1.isMergeBlocked
            }

            return false
        }
    }

    /// Number of stack parts the app knows about for the given PR; 1 when the PR is
    /// not stacked, so a stack is watched as a unit.
    func stackMemberCount(for pr: PullRequest) -> Int {
        stackMembers(of: pr).count
    }

    func toggleStackCollapse(_ stackID: String) {
        if collapsedStackIDs.contains(stackID) {
            collapsedStackIDs.remove(stackID)
        } else {
            collapsedStackIDs.insert(stackID)
        }
    }

    func isStackCollapsed(_ stackID: String) -> Bool {
        collapsedStackIDs.contains(stackID)
    }

    /// Number of stack parts the app knows about for the given stack id.
    func stackMemberCount(forStackID stackID: String) -> Int {
        stackMembers(stackID: stackID).count
    }

    /// The stack's known parts in merge order (part 1 first), for opening them all.
    func stackParts(inStack stackID: String) -> [PullRequest] {
        stackMembers(stackID: stackID).sorted {
            ($0.stack?.position ?? 0) < ($1.stack?.position ?? 0)
        }
    }

    func isStackWatched(_ stackID: String) -> Bool {
        stackMembers(stackID: stackID).contains { watchlistService.isWatched($0) }
    }

    /// Watches or unwatches every known part of a stack.
    func toggleWatchForStack(_ stackID: String) {
        let members = stackMembers(stackID: stackID)
        let shouldWatch = !members.contains { watchlistService.isWatched($0) }
        updateWatch(members, to: shouldWatch)
    }

    func toggleWatch(for pr: PullRequest) {
        let members = stackMembers(of: pr)
        let shouldWatch = !watchlistService.isWatched(pr)
        updateWatch(members, to: shouldWatch)
    }

    private func updateWatch(_ members: [PullRequest], to shouldWatch: Bool) {
        for member in members {
            if shouldWatch {
                watchlistService.watch(member)
            } else {
                watchlistService.unwatch(member)
            }
            setWatched(member.id, shouldWatch)
        }
    }

    private func stackMembers(of pr: PullRequest) -> [PullRequest] {
        guard let stackID = pr.stack?.id else { return [pr] }
        let members = stackMembers(stackID: stackID)
        return members.isEmpty ? [pr] : members
    }

    private func stackMembers(stackID: String) -> [PullRequest] {
        (unsortedPullRequests + otherPullRequests).filter { $0.stack?.id == stackID }
    }

    private func setWatched(_ prID: String, _ isWatched: Bool) {
        if let index = unsortedPullRequests.firstIndex(where: { $0.id == prID }) {
            unsortedPullRequests[index].isWatched = isWatched
        }
        if let index = pullRequests.firstIndex(where: { $0.id == prID }) {
            pullRequests[index].isWatched = isWatched
        }
        if let index = otherPullRequests.firstIndex(where: { $0.id == prID }) {
            otherPullRequests[index].isWatched = isWatched
        }
    }

    /// Notifies once per watched stack when it is ready to merge. A stack that
    /// becomes ready before anyone watches it stays pending, so watching it later
    /// still produces the notification on the next refresh. The ids of stacks
    /// already notified ready persist across launches; a stack that regresses is
    /// dropped from them so its recovery notifies again.
    private func notifyReadyStacks(allPRs: [PullRequest]) {
        let previouslyReady = readyStackIDs
        let transition = PRStackOrdering.readinessTransitions(previouslyReady: readyStackIDs, prs: allPRs)
        readyStackIDs = transition.readyStackIDs

        for readyStack in transition.newlyReady {
            let hasWatchedMember = allPRs.contains {
                $0.stack?.id == readyStack.id && watchlistService.isWatched($0)
            }
            guard hasWatchedMember else {
                readyStackIDs.remove(readyStack.id)
                continue
            }
            notificationService.notifyStackReady(stack: readyStack)
        }

        if readyStackIDs != previouslyReady {
            saveNotifiedReadyStackIDs(readyStackIDs)
        }
    }

    /// The stack ids already notified ready, persisted so a relaunch does not
    /// re-notify a stack that is still ready and still watched.
    private func loadNotifiedReadyStackIDs() -> Set<String> {
        guard let data = defaults.data(forKey: PreferenceKeys.notifiedReadyStacks),
              let ids = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(ids)
    }

    private func saveNotifiedReadyStackIDs(_ ids: Set<String>) {
        if let data = try? JSONEncoder().encode(ids.sorted()) {
            defaults.set(data, forKey: PreferenceKeys.notifiedReadyStacks)
        }
    }

    func clearAllWatched() {
        watchlistService.clearAll()
        for index in unsortedPullRequests.indices {
            unsortedPullRequests[index].isWatched = false
        }
        for index in pullRequests.indices {
            pullRequests[index].isWatched = false
        }
        for index in otherPullRequests.indices {
            otherPullRequests[index].isWatched = false
        }
    }

    func copyPRLink(for pr: PullRequest) {
        pasteboard.copy(pr.url)
        copiedPRID = pr.id
        copiedPRLinkTask?.cancel()
        copiedPRLinkTask = Task { [weak self, clock] in
            try? await clock.sleep(for: .seconds(2))
            self?.copiedPRID = nil
        }
    }

    private func checkGHAvailability() async {
        do {
            try await githubService.checkGHAvailable()
            isGHAvailable = true
            errorMessage = nil
        } catch let error as GitHubError {
            if error == .notInstalled || error == .notAuthenticated {
                isGHAvailable = false
            }
            errorMessage = error.localizedDescription
        } catch {
            isGHAvailable = false
            errorMessage = "Failed to check GitHub CLI availability"
        }
    }

    private func setupNotifications() {
        Task {
            try? await notificationService.requestAuthorization()
        }
    }
}

extension UserDefaults {
    @objc dynamic var sortNonSuccessFirstDisplay: Bool { bool(forKey: "sortNonSuccessFirst") }
    @objc dynamic var showReviewPRsDisplay: Bool { bool(forKey: "showReviewPRs") }
    @objc dynamic var hideInactivePRsDisplay: Bool { bool(forKey: "hideInactivePRs") }
}
