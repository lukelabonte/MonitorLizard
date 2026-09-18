import Testing
import Foundation
@testable import MonitorLizard

@MainActor
struct PRStackOrderingTests {

    private func makePR(
        _ number: Int,
        stackID: String = "stack-1",
        stackNumber: Int = 7,
        stackSize: Int = 4,
        position: Int,
        status: BuildStatus = .success,
        reviewDecision: ReviewDecision? = nil
    ) -> PullRequest {
        PullRequest(
            number: number,
            title: "PR #\(number)",
            repository: PullRequest.RepositoryInfo(name: "repo", nameWithOwner: "owner/repo"),
            url: "https://github.com/owner/repo/pull/\(number)",
            author: PullRequest.Author(login: "alice"),
            headRefName: "feature/\(number)",
            updatedAt: Date(timeIntervalSince1970: 1_000_000),
            buildStatus: status,
            isWatched: false,
            labels: [],
            type: .reviewing,
            isDraft: false,
            statusChecks: [],
            reviewDecision: reviewDecision,
            host: "github.com",
            stack: PRStackInfo(id: stackID, number: stackNumber, size: stackSize, position: position)
        )
    }

    private func makeUnstackedPR(_ number: Int) -> PullRequest {
        PullRequest(
            number: number,
            title: "PR #\(number)",
            repository: PullRequest.RepositoryInfo(name: "repo", nameWithOwner: "owner/repo"),
            url: "https://github.com/owner/repo/pull/\(number)",
            author: PullRequest.Author(login: "alice"),
            headRefName: "feature/\(number)",
            updatedAt: Date(timeIntervalSince1970: 1_000_000),
            buildStatus: .success,
            isWatched: false,
            labels: [],
            type: .reviewing,
            isDraft: false,
            statusChecks: [],
            reviewDecision: nil,
            host: "github.com"
        )
    }

    @Test func putsNewestStackPartOnTopWithBaseAtTheBottom() {
        let items = PRStackOrdering.items(from: [
            makePR(1, position: 1),
            makePR(3, position: 3),
            makePR(2, position: 2),
            makePR(4, position: 4),
        ])

        #expect(items.map(\.pr.number) == [4, 3, 2, 1])
        #expect(items.map(\.indentLevel) == [3, 2, 1, 0])
    }

    @Test func leavesUnstackedPRsInPlace() {
        let items = PRStackOrdering.items(from: [makeUnstackedPR(10), makeUnstackedPR(11)])

        #expect(items.map(\.pr.number) == [10, 11])
        #expect(items.map(\.indentLevel) == [0, 0])
    }

    @Test func keepsStackMembersAdjacentWhenOtherPRsSeparateThem() {
        let items = PRStackOrdering.items(from: [
            makeUnstackedPR(10),
            makePR(2, stackSize: 2, position: 2),
            makeUnstackedPR(11),
            makePR(1, stackSize: 2, position: 1),
        ])

        #expect(items.map(\.pr.number) == [10, 2, 1, 11])
        #expect(items.map(\.indentLevel) == [0, 1, 0, 0])
    }

    @Test func groupsMembersOfDifferentStacksSeparately() {
        let items = PRStackOrdering.items(from: [
            makePR(1, stackID: "a", stackSize: 2, position: 1),
            makePR(3, stackID: "b", stackSize: 2, position: 1),
            makePR(2, stackID: "a", stackSize: 2, position: 2),
            makePR(4, stackID: "b", stackSize: 2, position: 2),
        ])

        #expect(items.map(\.pr.number) == [2, 1, 4, 3])
        #expect(items.map(\.indentLevel) == [1, 0, 1, 0])
    }

    @Test func partialStackKeepsTruePositionLabels() {
        // Only positions 3 and 4 of a four-PR stack are visible. Indentation is
        // relative to the visible group; the labels carry the real position.
        let items = PRStackOrdering.items(from: [
            makePR(3, position: 3),
            makePR(4, position: 4),
        ])

        #expect(items.map(\.pr.number) == [4, 3])
        #expect(items.map(\.indentLevel) == [1, 0])
        #expect(items.map { $0.pr.stack?.positionLabel } == ["4/4", "3/4"])
    }

    @Test func singleVisibleStackMemberIsNotIndented() {
        let items = PRStackOrdering.items(from: [makePR(2, position: 2)])

        #expect(items.map(\.indentLevel) == [0])
        #expect(items.first?.pr.stack?.positionLabel == "2/4")
    }
}

@MainActor
struct PRStackReadinessTests {

    private func makePR(
        _ number: Int,
        position: Int,
        stackSize: Int,
        status: BuildStatus = .success,
        reviewDecision: ReviewDecision? = nil
    ) -> PullRequest {
        PullRequest(
            number: number,
            title: "PR #\(number)",
            repository: PullRequest.RepositoryInfo(name: "repo", nameWithOwner: "owner/repo"),
            url: "https://github.com/owner/repo/pull/\(number)",
            author: PullRequest.Author(login: "alice"),
            headRefName: "feature/\(number)",
            updatedAt: Date(timeIntervalSince1970: 1_000_000),
            buildStatus: status,
            isWatched: false,
            labels: [],
            type: .reviewing,
            isDraft: false,
            statusChecks: [],
            reviewDecision: reviewDecision,
            host: "github.com",
            stack: PRStackInfo(id: "stack-1", number: 42, size: stackSize, position: position)
        )
    }

    @Test func reportsLowestBlockedPart() {
        let readiness = PRStackOrdering.readiness(
            of: [
                makePR(1, position: 1, stackSize: 3),
                makePR(2, position: 2, stackSize: 3, status: .failure),
                makePR(3, position: 3, stackSize: 3),
            ],
            stackSize: 3
        )

        #expect(readiness.status == .blocked(.init(position: 2, number: 2, reason: "failing checks")))
        #expect(!readiness.isReadyToAdvance)
        #expect(readiness.helpText == "Waiting on part 2 of 3 (failing checks).")
    }

    @Test func pendingBasePartBlocksTheStack() {
        let readiness = PRStackOrdering.readiness(
            of: [makePR(1, position: 1, stackSize: 2, status: .pending)],
            stackSize: 2
        )

        #expect(readiness.status == .blocked(.init(position: 1, number: 1, reason: "checks pending")))
    }

    @Test func changesRequestedOnAnyPartBlocksTheStack() {
        let readiness = PRStackOrdering.readiness(
            of: [
                makePR(1, position: 1, stackSize: 2),
                makePR(2, position: 2, stackSize: 2, reviewDecision: .changesRequested),
            ],
            stackSize: 2
        )

        #expect(readiness.status == .blocked(.init(position: 2, number: 2, reason: "changes requested")))
    }

    @Test func allPartsVisibleAndReadyMeansAllReady() {
        let readiness = PRStackOrdering.readiness(
            of: [
                makePR(1, position: 1, stackSize: 2),
                makePR(2, position: 2, stackSize: 2),
            ],
            stackSize: 2
        )

        #expect(readiness.status == .allReady)
        #expect(readiness.isReadyToAdvance)
        #expect(readiness.helpText == "All 2 parts are ready to merge.")
    }

    @Test func baseReadyWithMissingPartsMeansReadyToAdvance() {
        let readiness = PRStackOrdering.readiness(
            of: [makePR(1, position: 1, stackSize: 4)],
            stackSize: 4
        )

        #expect(readiness.status == .readyToAdvance)
        #expect(readiness.isReadyToAdvance)
        #expect(readiness.helpText == "Part 1 is ready to merge.")
    }

    @Test func unreadyPartWithoutVisibleBaseIsUnknown() {
        let readiness = PRStackOrdering.readiness(
            of: [makePR(2, position: 2, stackSize: 4)],
            stackSize: 4
        )

        #expect(readiness.status == .unknown)
        #expect(!readiness.isReadyToAdvance)
        #expect(readiness.helpText == nil)
    }
}

@MainActor
struct PRStackReadinessTransitionTests {

    private func makePR(_ number: Int, position: Int, status: BuildStatus) -> PullRequest {
        PullRequest(
            number: number,
            title: "PR #\(number)",
            repository: PullRequest.RepositoryInfo(name: "repo", nameWithOwner: "owner/repo"),
            url: "https://github.com/owner/repo/pull/\(number)",
            author: PullRequest.Author(login: "alice"),
            headRefName: "feature/\(number)",
            updatedAt: Date(timeIntervalSince1970: 1_000_000),
            buildStatus: status,
            isWatched: false,
            labels: [],
            type: .reviewing,
            isDraft: false,
            statusChecks: [],
            reviewDecision: nil,
            host: "github.com",
            stack: PRStackInfo(id: "stack-1", number: 42, size: 2, position: position)
        )
    }

    @Test func reportsAStackOnceWhenItsBaseBecomesReady() {
        let ready = [makePR(1, position: 1, status: .success), makePR(2, position: 2, status: .success)]

        let first = PRStackOrdering.readinessTransitions(previouslyReady: [], prs: ready)
        let second = PRStackOrdering.readinessTransitions(previouslyReady: first.readyStackIDs, prs: ready)

        #expect(first.newlyReady.map(\.number) == [42])
        #expect(first.newlyReady.first?.allReady == true)
        #expect(second.newlyReady.isEmpty)
        #expect(second.readyStackIDs == first.readyStackIDs)
    }

    @Test func reportsASingleStackAcrossMultipleParts() {
        let ready = [makePR(1, position: 1, status: .success), makePR(2, position: 2, status: .success)]

        let result = PRStackOrdering.readinessTransitions(previouslyReady: [], prs: ready)

        #expect(result.newlyReady.count == 1)
    }

    @Test func doesNotReportAStackWhoseBaseIsNotVisible() {
        let prs = [makePR(2, position: 2, status: .success)]

        let result = PRStackOrdering.readinessTransitions(previouslyReady: [], prs: prs)

        #expect(result.newlyReady.isEmpty)
        #expect(result.readyStackIDs.isEmpty)
    }

    @Test func reportsAgainAfterTheStackRegressesAndRecovers() {
        let ready = [makePR(1, position: 1, status: .success)]
        let blocked = [makePR(1, position: 1, status: .failure)]

        let first = PRStackOrdering.readinessTransitions(previouslyReady: [], prs: ready)
        let regressed = PRStackOrdering.readinessTransitions(previouslyReady: first.readyStackIDs, prs: blocked)
        let recovered = PRStackOrdering.readinessTransitions(previouslyReady: regressed.readyStackIDs, prs: ready)

        #expect(first.newlyReady.count == 1)
        #expect(regressed.newlyReady.isEmpty)
        #expect(recovered.newlyReady.count == 1)
    }
}

@MainActor
struct PRStackInfoTests {

    @Test func labelsFirstStackEntryAsTheOneToMergeFirst() {
        let first = PRStackInfo(id: "stack-1", number: 42, size: 4, position: 1)

        #expect(first.positionLabel == "1/4")
        #expect(first.helpText == "Stack #42, part 1 of 4. Merge this one first.")
    }

    @Test func labelsLaterStackEntriesAsFollowingThePreviousPart() {
        let third = PRStackInfo(id: "stack-1", number: 42, size: 4, position: 3)

        #expect(third.positionLabel == "3/4")
        #expect(third.helpText == "Stack #42, part 3 of 4. Merge after part 2.")
    }
}
