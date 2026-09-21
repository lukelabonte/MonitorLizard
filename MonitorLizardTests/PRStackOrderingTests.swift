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
        reviewDecision: ReviewDecision? = nil,
        mergedPositions: [Int]? = nil
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
            stack: PRStackInfo(
                id: stackID,
                number: stackNumber,
                size: stackSize,
                position: position,
                mergedPositions: mergedPositions
            )
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

    private func header(_ rows: [PRListRow]) -> PRStackHeader? {
        guard case .stackHeader(let header) = rows.first else { return nil }
        return header
    }

    private func positions(_ rows: [PRListRow]) -> [Int] {
        rows.compactMap { $0.pr?.stack?.position }
    }

    @Test func rendersAStackAsOneBlockInMergeOrder() {
        let rows = PRStackOrdering.rows(from: [
            makePR(1, position: 1),
            makePR(3, position: 3),
            makePR(2, position: 2),
            makePR(4, position: 4),
        ])

        #expect(rows.count == 5)
        let header = header(rows)
        #expect(header?.number == 7)
        #expect(header?.size == 4)
        #expect(header?.visibleParts.map(\.number) == [1, 2, 3, 4])
        #expect(rows.compactMap(\.pr).map(\.number) == [1, 2, 3, 4])
        #expect(positions(rows) == [1, 2, 3, 4])
    }

    @Test func leavesUnstackedPRsAsPlainRows() {
        let rows = PRStackOrdering.rows(from: [makeUnstackedPR(10), makeUnstackedPR(11)])

        #expect(rows.count == 2)
        #expect(rows.compactMap(\.pr).map(\.number) == [10, 11])
        for row in rows {
            guard case .pr(_, let context) = row else {
                Issue.record("Expected a plain PR row")
                continue
            }
            #expect(context == nil)
        }
    }

    @Test func keepsAStackTogetherWhenOtherPRsSeparateThem() {
        let rows = PRStackOrdering.rows(from: [
            makeUnstackedPR(10),
            makePR(2, stackSize: 2, position: 2),
            makeUnstackedPR(11),
            makePR(1, stackSize: 2, position: 1),
        ])

        #expect(rows.compactMap(\.pr).map(\.number) == [10, 1, 2, 11])
        guard case .stackHeader = rows[1] else {
            Issue.record("Expected the stack header at index 1")
            return
        }
    }

    @Test func rendersEachStackAsItsOwnBlock() {
        let rows = PRStackOrdering.rows(from: [
            makePR(1, stackID: "a", stackSize: 2, position: 1),
            makePR(3, stackID: "b", stackSize: 2, position: 1),
            makePR(2, stackID: "a", stackSize: 2, position: 2),
            makePR(4, stackID: "b", stackSize: 2, position: 2),
        ])

        #expect(rows.compactMap(\.pr).map(\.number) == [1, 2, 3, 4])
        let headerCount = rows.filter { row in
            if case .stackHeader = row { return true }
            return false
        }.count
        #expect(headerCount == 2)
    }

    @Test func partialStackReportsOnlyTheVisibleParts() {
        // Only positions 3 and 4 of a four-PR stack are visible.
        let rows = PRStackOrdering.rows(from: [
            makePR(3, position: 3),
            makePR(4, position: 4),
        ])

        #expect(rows.compactMap(\.pr).map(\.number) == [3, 4])
        let header = header(rows)
        #expect(header?.visibleParts.map(\.position) == [3, 4])
        #expect(header?.summary == "2 of 4 parts in your lists")
    }

    @Test func singleVisibleStackMemberStillGetsABlock() {
        let rows = PRStackOrdering.rows(from: [makePR(2, position: 2)])

        #expect(rows.count == 2)
        #expect(header(rows)?.visibleParts.map(\.position) == [2])
        guard case .pr(_, let context) = rows[1] else {
            Issue.record("Expected the part row")
            return
        }
        #expect(context?.position == 2)
        #expect(context?.size == 4)
    }

    @Test func collapsedStackEmitsOnlyItsHeader() {
        let prs = [makePR(1, position: 1), makePR(2, position: 2)]

        let rows = PRStackOrdering.rows(from: prs, collapsedStackIDs: ["stack-1"])

        #expect(rows.count == 1)
        #expect(header(rows)?.size == 4)
    }

    @Test func marksOnlyTheBlockingPart() {
        let rows = PRStackOrdering.rows(from: [
            makePR(1, position: 1, status: .failure),
            makePR(2, position: 2),
        ])

        for row in rows {
            guard case .pr(let pr, let context) = row else { continue }
            #expect(context?.isBlocking == (pr.number == 1))
        }
    }

    @Test func marksTheBlockingUpperPartEvenWhenTheBaseIsReady() {
        let rows = PRStackOrdering.rows(from: [
            makePR(1, position: 1),
            makePR(2, position: 2, status: .failure),
        ])

        for row in rows {
            guard case .pr(let pr, let context) = row else { continue }
            #expect(context?.isBlocking == (pr.number == 2))
        }
    }

    @Test func mergedLowerPartsAreAccountedForInTheHeader() {
        let rows = PRStackOrdering.rows(from: [
            makePR(2, stackSize: 3, position: 2, mergedPositions: [1]),
            makePR(3, stackSize: 3, position: 3, mergedPositions: [1]),
        ])

        #expect(rows.compactMap(\.pr).map(\.number) == [2, 3])
        let header = header(rows)
        #expect(header?.readiness.status == .allReady)
        #expect(header?.visibleParts.map(\.number) == [2, 3])
        #expect(header?.summary == "Part 1 merged · All remaining parts are ready to merge")
    }

    @Test func mergedBaseNamesTheNextPartToMerge() {
        let rows = PRStackOrdering.rows(from: [
            makePR(2, stackSize: 3, position: 2, mergedPositions: [1]),
        ])

        #expect(header(rows)?.summary == "Part 1 merged · Ready to merge — start with #2")
    }

    @Test func mergedLowerPartsAndABlockedPartAreReportedTogether() {
        let rows = PRStackOrdering.rows(from: [
            makePR(2, stackSize: 3, position: 2, status: .failure, mergedPositions: [1]),
            makePR(3, stackSize: 3, position: 3, mergedPositions: [1]),
        ])

        #expect(header(rows)?.summary == "Part 1 merged · Blocked by part 2 (#2) — failing checks")
    }

    @Test func headerSummarizesTheStackState() {
        let blocked = header(PRStackOrdering.rows(from: [
            makePR(1, position: 1, status: .pending),
            makePR(2, position: 2),
        ]))
        #expect(blocked?.summary == "Blocked by part 1 (#1) — checks pending")

        let readyBaseWithPendingUpper = header(PRStackOrdering.rows(from: [
            makePR(1, stackSize: 2, position: 1),
            makePR(2, stackSize: 2, position: 2, status: .pending),
        ]))
        #expect(readyBaseWithPendingUpper?.summary == "Ready to merge — start with #1")

        let ready = header(PRStackOrdering.rows(from: [
            makePR(1, stackSize: 2, position: 1),
            makePR(2, stackSize: 2, position: 2),
        ]))
        #expect(ready?.summary == "All 2 parts are ready to merge")

        let waiting = header(PRStackOrdering.rows(from: [makePR(1, position: 1)]))
        #expect(waiting?.summary == "Ready to merge — start with #1")
    }
}

@MainActor
struct PRStackReadinessTests {

    private func makePR(
        _ number: Int,
        position: Int,
        stackSize: Int,
        status: BuildStatus = .success,
        reviewDecision: ReviewDecision? = nil,
        mergedPositions: [Int]? = nil
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
            stack: PRStackInfo(
                id: "stack-1",
                number: 42,
                size: stackSize,
                position: position,
                mergedPositions: mergedPositions
            )
        )
    }

    @Test func readyBaseWithABlockedUpperPartIsReadyToAdvance() {
        let readiness = PRStackOrdering.readiness(
            of: [
                makePR(1, position: 1, stackSize: 3),
                makePR(2, position: 2, stackSize: 3, status: .failure),
                makePR(3, position: 3, stackSize: 3),
            ],
            stackSize: 3
        )

        #expect(readiness.status == .readyToAdvance)
        #expect(readiness.isReadyToAdvance)
        #expect(readiness.blockingPart == .init(position: 2, number: 2, reason: "failing checks"))
    }

    @Test func pendingBasePartBlocksTheStack() {
        let readiness = PRStackOrdering.readiness(
            of: [makePR(1, position: 1, stackSize: 2, status: .pending)],
            stackSize: 2
        )

        #expect(readiness.status == .blocked(.init(position: 1, number: 1, reason: "checks pending")))
    }

    @Test func readyBaseWithChangesRequestedOnAnUpperPartIsReadyToAdvance() {
        let readiness = PRStackOrdering.readiness(
            of: [
                makePR(1, position: 1, stackSize: 2),
                makePR(2, position: 2, stackSize: 2, reviewDecision: .changesRequested),
            ],
            stackSize: 2
        )

        #expect(readiness.status == .readyToAdvance)
        #expect(readiness.isReadyToAdvance)
        #expect(readiness.blockingPart == .init(position: 2, number: 2, reason: "changes requested"))
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

    @Test func mergedBaseLetsTheStackAdvance() {
        let readiness = PRStackOrdering.readiness(
            of: [
                makePR(2, position: 2, stackSize: 3, mergedPositions: [1]),
                makePR(3, position: 3, stackSize: 3, mergedPositions: [1]),
            ],
            stackSize: 3
        )

        #expect(readiness.status == .allReady)
        #expect(readiness.landedPositions == [1])
        #expect(readiness.landedText == "Part 1 merged")
        #expect(readiness.isReadyToAdvance)
        #expect(readiness.helpText == "Part 1 merged. All remaining parts are ready to merge.")
    }

    @Test func mergedBaseWithMissingUpperPartsIsReadyToAdvance() {
        let readiness = PRStackOrdering.readiness(
            of: [makePR(2, position: 2, stackSize: 3, mergedPositions: [1])],
            stackSize: 3
        )

        #expect(readiness.status == .readyToAdvance)
        #expect(readiness.isReadyToAdvance)
        #expect(readiness.helpText == "Part 1 merged. The next part is ready to merge.")
    }

    @Test func mergedTextListsEveryLandedPosition() {
        let readiness = PRStackOrdering.readiness(
            of: [makePR(3, position: 3, stackSize: 3, mergedPositions: [1, 2])],
            stackSize: 3
        )

        #expect(readiness.landedText == "Parts 1, 2 merged")
        #expect(readiness.status == .allReady)
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

    @Test func blockedUpperPartWithoutVisibleBaseIsUnknownButStillNamesTheBlocker() {
        // Position 1 is neither visible nor known-merged, so readiness cannot be
        // judged — but the blocked part stays exposed so its row keeps the
        // blocking marker.
        let readiness = PRStackOrdering.readiness(
            of: [
                makePR(2, position: 2, stackSize: 4),
                makePR(3, position: 3, stackSize: 4, status: .failure),
            ],
            stackSize: 4
        )

        #expect(readiness.status == .unknown)
        #expect(!readiness.isReadyToAdvance)
        #expect(readiness.blockingPart == .init(position: 3, number: 3, reason: "failing checks"))
    }
}

@MainActor
struct PRStackReadinessTransitionTests {

    private func makePR(
        _ number: Int,
        position: Int,
        status: BuildStatus,
        stackSize: Int = 2,
        mergedPositions: [Int]? = nil
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
            reviewDecision: nil,
            host: "github.com",
            stack: PRStackInfo(
                id: "stack-1",
                number: 42,
                size: stackSize,
                position: position,
                mergedPositions: mergedPositions
            )
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

    @Test func reportsAStackOnceWhenItsBaseIsReadyAndAnUpperPartIsBlocked() {
        let readyBase = [
            makePR(1, position: 1, status: .success),
            makePR(2, position: 2, status: .failure),
        ]

        let first = PRStackOrdering.readinessTransitions(previouslyReady: [], prs: readyBase)
        let second = PRStackOrdering.readinessTransitions(previouslyReady: first.readyStackIDs, prs: readyBase)

        #expect(first.newlyReady.count == 1)
        #expect(first.newlyReady.first?.allReady == false)
        #expect(first.newlyReady.first?.nextPartPosition == 1)
        #expect(second.newlyReady.isEmpty)
    }

    @Test func namesTheNextPartWhenLowerPartsHaveMerged() {
        let prs = [makePR(2, position: 2, status: .success, stackSize: 3, mergedPositions: [1])]

        let result = PRStackOrdering.readinessTransitions(previouslyReady: [], prs: prs)

        #expect(result.newlyReady.count == 1)
        #expect(result.newlyReady.first?.allReady == false)
        #expect(result.newlyReady.first?.nextPartPosition == 2)
        #expect(result.newlyReady.first?.landedPositions == [1])
    }

    @Test func doesNotNameTheNextPartWhenAMiddlePositionIsUnknown() {
        // Position 1 has merged and position 3 is ready, but position 2 is
        // neither visible nor known-merged, so the part to merge next cannot be
        // named: part 3 might not be reachable yet.
        let prs = [makePR(3, position: 3, status: .success, stackSize: 4, mergedPositions: [1])]

        let result = PRStackOrdering.readinessTransitions(previouslyReady: [], prs: prs)

        #expect(result.newlyReady.count == 1)
        #expect(result.newlyReady.first?.allReady == false)
        #expect(result.newlyReady.first?.nextPartPosition == nil)
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
