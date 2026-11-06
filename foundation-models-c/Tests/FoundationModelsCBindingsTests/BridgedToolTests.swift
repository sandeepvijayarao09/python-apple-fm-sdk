/*
For licensing see accompanying LICENSE file.
Copyright (C) 2026 Apple Inc. All Rights Reserved.
*/

import Foundation
import FoundationModels
import FoundationModelsCDeclarations
import Synchronization
import Testing

@testable import FoundationModelsCBindings

/// The tool under test. The C callback below has no context pointer, so it
/// finds the tool through this global.
nonisolated(unsafe) private var immediateTool: FMBridgedToolRef?

/// A foreign callback that finishes the call before returning, the way a fast
/// Python tool running on its own thread can finish before
/// `BridgedTool.call(arguments:)` gets back from `foreignCall`.
private let finishImmediately: @convention(c) (FMGeneratedContentRef, CUnsignedInt) -> Void = {
  content, callId in
  Unmanaged<AnyObject>.fromOpaque(content).release()
  FMBridgedToolFinishCall(immediateTool!, callId, "done")
}

@Suite(.serialized) struct BridgedToolTests {
  @Test func testCallResumesWhenFinishedBeforeForeignCallReturns() async throws {
    let schema = try GenerationSchema(
      root: DynamicGenerationSchema(name: "Empty", properties: []),
      dependencies: []
    )
    let tool = BridgedTool(
      name: "immediate",
      description: "Finishes every call synchronously",
      parameters: schema,
      foreignCall: finishImmediately
    )
    immediateTool = FMBridgedToolRef(Unmanaged.passUnretained(tool).toOpaque())
    defer { immediateTool = nil }

    // Run the call in an unstructured task so a regression shows up as a test
    // failure rather than a hung test run.
    let result = Mutex<String?>(nil)
    Task {
      let output = try await tool.call(arguments: GeneratedContent(properties: [:]))
      result.withLock { $0 = output }
    }

    let deadline = ContinuousClock.now + .seconds(5)
    while result.withLock({ $0 }) == nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(result.withLock { $0 } == "done")
  }
}
