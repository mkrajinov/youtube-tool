import Foundation
import Testing
@testable import YouTubeCore

@Suite struct LinkTests {
    @Test func classifiesVideos() {
        #expect(YouTubeLink.classify("https://www.youtube.com/watch?v=abc") == .video(url: "https://www.youtube.com/watch?v=abc", playlistURL: nil))
        #expect(YouTubeLink.classify("https://youtu.be/abc?t=3") == .video(url: "https://youtu.be/abc?t=3", playlistURL: nil))
        #expect(YouTubeLink.classify("https://www.youtube.com/shorts/abc") == .video(url: "https://www.youtube.com/shorts/abc", playlistURL: nil))
        #expect(YouTubeLink.classify("https://example.com/watch?v=abc") == nil)
    }

    @Test func videoFromPlaylistOffersThePlaylist() {
        let link = YouTubeLink.classify("https://www.youtube.com/watch?v=abc&list=PL123&index=4")
        #expect(link == .video(url: "https://www.youtube.com/watch?v=abc&list=PL123&index=4",
                               playlistURL: "https://www.youtube.com/playlist?list=PL123"))
    }

    @Test func classifiesPlaylists() {
        #expect(YouTubeLink.classify("https://www.youtube.com/playlist?list=PL123") == .playlist(url: "https://www.youtube.com/playlist?list=PL123"))
        #expect(YouTubeLink.classify("https://music.youtube.com/playlist?list=OLAK5") == .playlist(url: "https://www.youtube.com/playlist?list=OLAK5"))
        #expect(YouTubeLink.classify("https://www.youtube.com/playlist") == nil)
    }

    @Test func channelsGoToTheirVideosTab() {
        #expect(YouTubeLink.classify("https://www.youtube.com/@3blue1brown") == .playlist(url: "https://www.youtube.com/@3blue1brown/videos"))
        #expect(YouTubeLink.classify("https://youtube.com/@x/featured") == .playlist(url: "https://www.youtube.com/@x/videos"))
        #expect(YouTubeLink.classify("https://www.youtube.com/@x/shorts") == .playlist(url: "https://www.youtube.com/@x/shorts"))
        #expect(YouTubeLink.classify("https://www.youtube.com/channel/UC1") == .playlist(url: "https://www.youtube.com/channel/UC1/videos"))
    }

    @Test func extractsLinksFromAnyText() {
        let text = """
        My list:
        1. https://www.youtube.com/watch?v=aaa, great
        - youtu.be/bbb.
        [link](https://www.youtube.com/watch?v=ccc)
        https://www.youtube.com/watch?v=aaa
        not a link: https://example.com/watch?v=ddd
        """
        #expect(LinkExtractor.links(in: text) == [
            "https://www.youtube.com/watch?v=aaa",
            "https://youtu.be/bbb",
            "https://www.youtube.com/watch?v=ccc",
        ])
    }

    @Test func splitsLinksSeparatedBySpaces() {
        #expect(LinkExtractor.links(in: "https://youtu.be/a https://youtu.be/b").count == 2)
    }
}

@Suite struct PlaylistDecodingTests {
    @Test func decodesFlatPlaylist() throws {
        let json = """
        {"id":"PL1","title":"Mix","channel":"Music","_type":"playlist","entries":[
          {"_type":"url","ie_key":"Youtube","id":"aaaaaaaaaaa","title":"One","duration":61,
           "url":"https://www.youtube.com/watch?v=aaaaaaaaaaa","channel":"Artist"},
          {"_type":"url","ie_key":"Youtube","id":"bbbbbbbbbbb","title":"[Private video]","duration":null,
           "url":"https://www.youtube.com/watch?v=bbbbbbbbbbb"},
          {"_type":"url","ie_key":"Youtube","id":"aaaaaaaaaaa","title":"One again","duration":61}
        ]}
        """
        let info = try JSONDecoder().decode(PlaylistInfo.self, from: Data(json.utf8))
        #expect(info.title == "Mix")
        #expect(info.entries.count == 2)  // duplicate dropped
        #expect(info.entries[0] == PlaylistEntry(id: "aaaaaaaaaaa", title: "One", url: "https://www.youtube.com/watch?v=aaaaaaaaaaa",
                                                 duration: 61, channel: "Artist", index: 1))
        #expect(info.entries[1].isUnavailable)
        #expect(info.entries[1].channel == "Music")  // falls back to the playlist's channel
        #expect(info.totalDuration == 61)
    }

    @Test func flattensChannelTabs() throws {
        let json = """
        {"id":"@x","title":"X","entries":[
          {"_type":"playlist","title":"X - Videos","entries":[{"ie_key":"Youtube","id":"v1","title":"A"}]},
          {"_type":"playlist","title":"X - Shorts","entries":[{"ie_key":"Youtube","id":"v2","title":"B"}]},
          {"_type":"url","ie_key":"YoutubeTab","id":"PLother","title":"A playlist"}
        ]}
        """
        let info = try JSONDecoder().decode(PlaylistInfo.self, from: Data(json.utf8))
        #expect(info.entries.map(\.id) == ["v1", "v2"])
        #expect(info.entries.map(\.index) == [1, 2])
        #expect(info.entries[0].url == "https://www.youtube.com/watch?v=v1")
    }
}

@Suite struct PlaylistNamingTests {
    @Test func folderNames() {
        #expect(PlaylistNaming.folderName("Best of 2024/2025: Live") == "Best of 2024-2025 - Live")
        #expect(PlaylistNaming.folderName("  ...  ") == "Playlist")
        #expect(PlaylistNaming.folderName(".hidden") == "hidden")
    }

    @Test func numberPrefixes() {
        #expect(PlaylistNaming.numberPrefix(index: 7, count: 40) == "07 - ")
        #expect(PlaylistNaming.numberPrefix(index: 7, count: 120) == "007 - ")
        #expect(PlaylistNaming.numberPrefix(index: 12, count: 9) == "12 - ")
    }

    @Test func outputTemplateEscapesPercent() {
        #expect(YTDLPArguments.outputTemplate(prefix: "100% - ") == "100%% - %(title)s [%(id)s].%(ext)s")
        let options = DownloadOptions(mode: .audio, outputDirectory: URL(fileURLWithPath: "/d"), filePrefix: "03 - ")
        let args = YTDLPArguments.download(url: "https://youtu.be/x", options: options)
        #expect(args.contains("03 - %(title)s [%(id)s].%(ext)s"))
    }

    @Test func findsExistingDownloads() {
        let names = ["Song [aaaaaaaaaaa].m4a", "07 - Other [bbbbbbbbbbb].m4a", "Video [ccccccccccc].mp4",
                     "Part [ddddddddddd].m4a.part", "Song [aaaaaaaaaaa].transcript.txt", "No id.m4a"]
        #expect(ExistingDownloads.ids(fromFileNames: names, fileExtension: "m4a") == ["aaaaaaaaaaa", "bbbbbbbbbbb"])
        #expect(ExistingDownloads.ids(fromFileNames: names, fileExtension: "mp4") == ["ccccccccccc"])
    }

    @Test func playlistArguments() {
        let args = YTDLPArguments.playlist(url: "https://www.youtube.com/playlist?list=PL1")
        #expect(args.contains("--flat-playlist"))
        #expect(args.suffix(2) == ["--", "https://www.youtube.com/playlist?list=PL1"])
    }
}
