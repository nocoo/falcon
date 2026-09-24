import Foundation
import Testing
@testable import FalconCore

@Test func jsonPreservesStructuredDefinitions() throws {
    let data = Data(#"{"state":["text",1,true,null],"define":{"nested":false},"number":0.5}"#.utf8)
    let value = try JSONValue.decode(data)
    #expect(try JSONValue.decode(value.data()) == value)
    #expect(value["state"]?.arrayValue?.count == 4)
    #expect(value["define"]?["nested"]?.boolValue == false)
    #expect(value["number"]?.numberValue == 0.5)
    #expect(JSONValue.string("plain").displayText == "plain")
    #expect(throws: (any Error).self) { try JSONValue.decode(Data("{".utf8)) }
}

@Test func timingNeverInventsUnknownIntervals() {
    #expect(RequestTiming().upstreamMS == nil)
    let timing = RequestTiming(bodyReceivedMS: 3, upstreamStartedMS: 10, responseReceivedMS: 210, terminalMS: 215)
    #expect(timing.upstreamMS == 200)
    #expect(timing.lastKnownMS == 215)
    #expect(timing.deliveryFinishedMS == nil)
    #expect(!RequestStatus.inFlight.isTerminal)
    #expect(RequestStatus.interrupted.isFailure)
}
