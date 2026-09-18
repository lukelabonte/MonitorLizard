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

/// One part of a stack that is visible in a section.
struct PRStackPart: Hashable {
    let position: Int
    let number: Int
}

/// The row that introduces a stack block: identity and state for the whole stack,
/// so the information is not repeated on every part row.
struct PRStackHeader: Hashable, Identifiable {
    let stackID: String
    let number: Int
    let size: Int

    /// The stack's parts that are visible in this section, ascending by position.
    let visibleParts: [PRStackPart]

    let readiness: PRStackReadiness

    /// True when any visible part has status checks, so the stack can be watched.
    let hasStatusChecks: Bool

    var id: String { "stack-\(stackID)" }

    /// The part closest to the base branch, when it is visible.
    var basePart: PRStackPart? {
        visibleParts.first { $0.position == 1 }
    }

    /// One-line state summary shown next to the stack number.
    var summary: String {
        switch readiness.status {
        case .allReady:
            return "All \(size) parts are ready to merge"
        case .readyToAdvance:
            if let basePart {
                return "Ready to merge — start with #\(basePart.number)"
            }
            return "Ready to merge"
        case .blocked(let blocker):
            return "Blocked by part \(blocker.position) (#\(blocker.number)) — \(blocker.reason)"
        case .unknown:
            return "\(visibleParts.count) of \(size) parts in your lists"
        }
    }

    /// Tooltip listing the parts the app can see.
    var helpText: String {
        let parts = visibleParts
            .map { "#\($0.number) (\($0.position)/\(size))" }
            .joined(separator: ", ")
        var text = "Stack #\(number) — \(size) parts. Visible here: \(parts)."
        if let readinessText = readiness.helpText {
            text += " \(readinessText)"
        }
        return text
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

    /// One-line explanation for tooltips, or nil when the stack's state cannot be
    /// judged.
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

/// A row in a section: a stack block's header, or a PR.
enum PRListRow: Identifiable, Hashable {
    case stackHeader(PRStackHeader)
    case pr(PullRequest, StackRowContext?)

    /// Where a PR sits when it is rendered as a part inside a stack block.
    struct StackRowContext: Hashable {
        let position: Int
        let size: Int
        /// True when this part is the one everything above it is waiting on.
        let isBlocking: Bool
        let helpText: String
    }

    var id: String {
        switch self {
        case .stackHeader(let header): return header.id
        case .pr(let pr, _): return pr.id
        }
    }

    /// The PR this row shows, or nil for a stack header.
    var pr: PullRequest? {
        guard case .pr(let pr, _) = self else { return nil }
        return pr
    }
}

enum PRStackOrdering {
    /// Rows for a section: PRs without a stack stay as they are, and each stack
    /// becomes one block — a header followed by its visible parts in merge order,
    /// part 1 (the one closest to the base branch) first.
    ///
    /// A block is emitted where its first member appears in `prs`, so a stack does
    /// not move around while the rest of the list changes. Collapsed stacks emit
    /// only their header.
    static func rows(from prs: [PullRequest], collapsedStackIDs: Set<String> = []) -> [PRListRow] {
        var membersByStack: [String: [PullRequest]] = [:]
        for pr in prs {
            guard let stack = pr.stack else { continue }
            membersByStack[stack.id, default: []].append(pr)
        }

        var emittedStacks: Set<String> = []
        var rows: [PRListRow] = []

        for pr in prs {
            guard let stack = pr.stack,
                  let members = membersByStack[stack.id] else {
                rows.append(.pr(pr, nil))
                continue
            }
            guard emittedStacks.insert(stack.id).inserted else { continue }

            let readiness = readiness(of: members, stackSize: stack.size)
            let visibleParts = members
                .compactMap { member -> PRStackPart? in
                    guard let memberStack = member.stack else { return nil }
                    return PRStackPart(position: memberStack.position, number: member.number)
                }
                .sorted { $0.position < $1.position }

            rows.append(.stackHeader(PRStackHeader(
                stackID: stack.id,
                number: stack.number,
                size: stack.size,
                visibleParts: visibleParts,
                readiness: readiness,
                hasStatusChecks: members.contains { $0.hasStatusChecks }
            )))

            guard !collapsedStackIDs.contains(stack.id) else { continue }

            let ordered = members.sorted {
                ($0.stack?.position ?? 0) < ($1.stack?.position ?? 0)
            }
            for member in ordered {
                guard let memberStack = member.stack else { continue }
                var isBlocking = false
                if case .blocked(let blocker) = readiness.status, blocker.number == member.number {
                    isBlocking = true
                }
                let helpText = [memberStack.helpText, readiness.helpText]
                    .compactMap { $0 }
                    .joined(separator: " ")
                rows.append(.pr(member, PRListRow.StackRowContext(
                    position: memberStack.position,
                    size: memberStack.size,
                    isBlocking: isBlocking,
                    helpText: helpText
                )))
            }
        }

        return rows
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
