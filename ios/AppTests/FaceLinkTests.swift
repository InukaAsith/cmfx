import Foundation
import Testing
@testable import CMFX

struct FaceLinkTests {
    @Test(arguments: [
        "fmc://install?id=ql801euz9rzjkk6",
        "fmc://install?url=https%3A%2F%2Ffmc.tools%2Fapi%2Ffiles%2Fpbc_984338259%2Fql801euz9rzjkk6%2Fcmf_8_bit_ecmsj3q1z9.bin",
        "https://fmc.tools/market/ql801euz9rzjkk6",
    ])
    func opensTheRecord(_ link: String) {
        #expect(FaceLink.watchface(URL(string: link)!) == "ql801euz9rzjkk6")
    }

    @Test(arguments: [
        // a file anywhere else: the app never fetches from a link
        "fmc://install?url=https%3A%2F%2Fevil.example%2Fapi%2Ffiles%2Fc%2Fql801euz9rzjkk6%2Fx.bin",
        "fmc://install?url=http%3A%2F%2Ffmc.tools%2Fapi%2Ffiles%2Fc%2Fql801euz9rzjkk6%2Fx.bin",
        "fmc://install?id=x%27%20%7C%7C%20owner%20%21%3D%20%27",
        "fmc://install?id=QL801EUZ9RZJKK6",
        "fmc://other?id=ql801euz9rzjkk6",
        "https://fmc.tools.evil.example/market/ql801euz9rzjkk6",
        "https://fmc.tools/market/ql801euz9rzjkk6/edit",
        "http://fmc.tools/market/ql801euz9rzjkk6",
    ])
    func rejects(_ link: String) {
        #expect(FaceLink.watchface(URL(string: link)!) == nil)
    }

    @Test func decodesARecord() throws {
        let json = """
        {"id":"ql801euz9rzjkk6","collectionId":"pbc_984338259","name":"[CMF] 8-Bit","description":"",
         "preview":"preview_s60dq7bcph.png","bin":"cmf_8_bit_ecmsj3q1z9.bin","published":true,"downloads":2,"created":"",
         "device":"watch_pro_2","expand":{"owner":{"id":"mrwcguo74bjb4gt","name":"Yakashi"}}}
        """
        let face = try JSONDecoder().decode(Watchface.self, from: Data(json.utf8))
        #expect(face.author == "Yakashi")
        #expect(face.binURL?.absoluteString == "https://fmc.tools/api/files/pbc_984338259/ql801euz9rzjkk6/cmf_8_bit_ecmsj3q1z9.bin")
        #expect(face.pageURL.absoluteString == "https://fmc.tools/market/ql801euz9rzjkk6")
    }
}
