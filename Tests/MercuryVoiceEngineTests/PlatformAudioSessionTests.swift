import Testing
@testable import MercuryVoiceEngine

@Suite("platform audio session")
struct PlatformAudioSessionTests {
    /// iOS and visionOS share AVAudioSession; both must take the iOS path.
    @Test func bargeMuteFollowsTheAudioSessionPlatforms() {
        #if os(iOS) || os(visionOS)
            #expect(bargeMuteRunsOnIOS)
        #else
            #expect(!bargeMuteRunsOnIOS)
        #endif
    }
}
