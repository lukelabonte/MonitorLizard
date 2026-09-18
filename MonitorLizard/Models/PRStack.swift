import Foundation

/// A pull request's membership in a GitHub stack: a series of open PRs where each
/// PR targets the branch of the PR below it.
struct PRStackInfo: Hashable, Codable {
    /// Stable identifier of the stack (GitHub GraphQL node ID).
    let id: String

    /// A number uniquely identifying the stack within its repository.
    let number: Int

    /// The total number of pull requests in the stack.
    let size: Int

    /// This pull request's position in the stack, where 1 is closest to the base branch.
    let position: Int

    /// Short label matching GitHub's stack chip (e.g. "1/4").
    var positionLabel: String {
        "\(position)/\(size)"
    }

    /// Tooltip explaining where this PR sits in the merge order.
    var helpText: String {
        let header = "Stack #\(number), part \(position) of \(size)"
        return position == 1
            ? "\(header). Merge this one first."
            : "\(header). Merge after part \(position - 1)."
    }
}

/// Identifies a stack that has become ready to merge, with enough context for a
/// notification.
struct ReadyStack: Hashable {
    let id: String
    let number: Int
    let size: Int

    /// True when every part of the stack is visible and ready; false when only the
    /// lowest part is known to be ready.
    let allReady: Bool
}

/// What the app can say about a stack's readiness to merge, based on the parts it
/// can see. A stack can only advance from its lowest part, so the lowest part that
/// is not ready is what everything above it is waiting on.
struct PRStackReadiness: Hashable {
    enum Status: Hashable {
        /// Every part of the stack is visible and ready to merge.
        case allReady
        /// The lowest part is ready, so merging can start.
        case readyToAdvance
        /// A specific part is not ready, and everything above it waits.
        case blocked(PRStackBlocker)
        /// Not enough of the stack is visible to judge.
        case unknown
    }

    struct PRStackBlocker: Hashable {
        let position: Int
        let number: Int
        let reason: String
    }

    let status: Status
    let size: Int

    /// True when the lowest part is ready, whether or not the parts above it are.
    var isReadyToAdvance: Bool {
        switch status {
        case .allReady, .readyToAdvance: return true
        case .blocked, .unknown: return false
        }
    }

    /// One-line explanation for the stack chip's tooltip, or nil when the stack's
    /// state cannot be judged.
    var helpText: String? {
        switch status {
        case .allReady:
            return "All \(size) parts are ready to merge."
        case .readyToAdvance:
            return "Part 1 is ready to merge."
        case .blocked(let blocker):
            return "Waiting on part \(blocker.position) of \(size) (\(blocker.reason))."
        case .unknown:
            return nil
        }
    }
}

/// A pull request as it should appear in a section of the menu, together with the
/// indentation that shows where it sits in its stack.
struct PRListItem: Identifiable, Hashable {
    let pr: PullRequest

    /// 0 for an unstacked PR or the part closest to the base branch, increasing
    /// toward the top of the stack. This matches GitHub's stack popover, which puts
    /// the base at the bottom and the newest part at the top.
    let indentLevel: Int

    /// Readiness of the PR's stack, or nil when the PR is not stacked.
    let stackReadiness: PRStackReadiness?

    var id: String { pr.id }
}

enum PRStackOrdering {
    /// Groups PRs that belong to the same stack so they render next to each other
    /// with the newest part on top, matching GitHub's stack popover: the part
    /// closest to the base branch sits at the bottom with no indentation and each
    /// part above it is indented one step further.
    ///
    /// A stack is emitted where its first member appears in `prs`; PRs that are not
    /// part of a stack keep their existing relative order. Only members visible in
    /// `prs` participate, so a partially visible stack still renders in order (its
    /// labels carry the true position within the whole stack).
    static func items(from prs: [PullRequest]) -> [PRListItem] {
        var membersByStack: [String: [PullRequest]] = [:]
        for pr in prs {
            guard let stack = pr.stack else { continue }
            membersByStack[stack.id, default: []].append(pr)
        }

        var emittedStacks: Set<String> = []
        var items: [PRListItem] = []

        for pr in prs {
            guard let stack = pr.stack,
                  let members = membersByStack[stack.id],
                  members.count > 1 else {
                items.append(PRListItem(pr: pr, indentLevel: 0, stackReadiness: readiness(for: pr)))
                continue
            }
            guard emittedStacks.insert(stack.id).inserted else { continue }

            let stackReadiness = readiness(of: members, stackSize: stack.size)
            let ordered = members.sorted {
                ($0.stack?.position ?? 0) > ($1.stack?.position ?? 0)
            }
            for (index, member) in ordered.enumerated() {
                items.append(PRListItem(
                    pr: member,
                    indentLevel: ordered.count - 1 - index,
                    stackReadiness: stackReadiness
                ))
            }
        }

        return items
    }

    /// Readiness of a stack from the parts the app can see.
    static func readiness(of members: [PullRequest], stackSize: Int) -> PRStackReadiness {
        let ordered = members.sorted {
            ($0.stack?.position ?? 0) < ($1.stack?.position ?? 0)
        }

        if let blocker = ordered.first(where: { $0.isMergeBlocked }) {
            return PRStackReadiness(
                status: .blocked(PRStackReadiness.PRStackBlocker(
                    position: blocker.stack?.position ?? 0,
                    number: blocker.number,
                    reason: blocker.mergeBlockReason ?? "not ready"
                )),
                size: stackSize
            )
        }

        let hasBase = ordered.contains { $0.stack?.position == 1 }
        guard hasBase else {
            return PRStackReadiness(status: .unknown, size: stackSize)
        }
        let status: PRStackReadiness.Status = ordered.count == stackSize ? .allReady : .readyToAdvance
        return PRStackReadiness(status: status, size: stackSize)
    }

    private static func readiness(for pr: PullRequest) -> PRStackReadiness? {
        guard let stack = pr.stack else { return nil }
        return readiness(of: [pr], stackSize: stack.size)
    }

    /// Stacks whose lowest part has just become ready to merge.
    ///
    /// - Parameter previouslyReady: Stack ids that were ready at the previous call.
    /// - Returns: The stacks that are newly ready, and the ids to pass as
    ///   `previouslyReady` next time.
    static func readinessTransitions(
        previouslyReady: Set<String>,
        prs: [PullRequest]
    ) -> (newlyReady: [ReadyStack], readyStackIDs: Set<String>) {
        var membersByStack: [String: [PullRequest]] = [:]
        var stackNumbers: [String: Int] = [:]
        var stackSizes: [String: Int] = [:]
        for pr in prs {
            guard let stack = pr.stack else { continue }
            membersByStack[stack.id, default: []].append(pr)
            stackNumbers[stack.id] = stack.number
            stackSizes[stack.id] = stack.size
        }

        var readyStackIDs: Set<String> = []
        var newlyReady: [ReadyStack] = []

        for (stackID, members) in membersByStack {
            let stackSize = stackSizes[stackID] ?? members.count
            let readiness = readiness(of: members, stackSize: stackSize)
            guard readiness.isReadyToAdvance else { continue }

            readyStackIDs.insert(stackID)
            guard !previouslyReady.contains(stackID) else { continue }

            newlyReady.append(ReadyStack(
                id: stackID,
                number: stackNumbers[stackID] ?? 0,
                size: stackSize,
                allReady: readiness.status == .allReady
            ))
        }

        return (newlyReady.sorted { $0.number < $1.number }, readyStackIDs)
    }
}
