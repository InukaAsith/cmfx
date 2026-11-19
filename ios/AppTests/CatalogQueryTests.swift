import Foundation
import Testing
@testable import CMFX

/// Same cases as android CatalogQueryTest.kt.
struct CatalogQueryTests {
    let me = "852gi1yb7gjr4tk"

    @Test func shelves() {
        #expect(CatalogQuery().filter == "published = true")
        #expect(CatalogQuery(shelf: .mine, user: me).filter == "owner = '852gi1yb7gjr4tk'")
        #expect(CatalogQuery(shelf: .liked, user: me).filter
                == "published = true && likes_via_watchface.user ?= '852gi1yb7gjr4tk'")
        // signed out, or an id that isn't one: nothing to ask for
        #expect(CatalogQuery(shelf: .liked).filter == nil)
        #expect(CatalogQuery(shelf: .mine, user: "x' || owner != '").filter == nil)
    }

    @Test func searchesNameAndAuthor() {
        #expect(CatalogQuery(search: "  Neo ").filter == "published = true && (name ~ 'Neo' || owner.name ~ 'Neo')")
        // a quote can't end the literal
        #expect(CatalogQuery(search: "it's\\").filter
                == "published = true && (name ~ 'it\\'s\\\\' || owner.name ~ 'it\\'s\\\\')")
    }

    @Test func sorts() {
        #expect(CatalogQuery(sort: .new).order() == "-created,id")
        #expect(CatalogQuery(sort: .popular).order() == "-likes_count,-downloads,id")
        #expect(CatalogQuery(sort: .popular).order(likesCount: false) == "-downloads,-created,id")
        #expect(CatalogQuery(sort: .downloads).order() == "-downloads,-created,id")
    }

    @Test func cachesOnlyTheUnsearchedAll() {
        #expect(CatalogQuery(sort: .popular).cacheName == "catalog-popular")
        #expect(CatalogQuery(search: "a").cacheName == nil)
        #expect(CatalogQuery(shelf: .mine, user: me).cacheName == nil)
    }

    @Test func nextPageNearTheEnd() {
        #expect(!CatalogQuery.nearEnd(31, of: 40))
        #expect(CatalogQuery.nearEnd(32, of: 40))
        #expect(CatalogQuery.nearEnd(0, of: 3))
    }

    @Test func readsTheCountWhenTheServerHasIt() throws {
        let with = #"{"id":"a","collectionId":"c","name":"n","description":"","preview":"p.png","bin":"b.bin","published":true,"downloads":1,"created":"","likes_count":7}"#
        let without = #"{"id":"a","collectionId":"c","name":"n","description":"","preview":"p.png","bin":"b.bin","published":true,"downloads":1,"created":""}"#
        #expect(try JSONDecoder().decode(Watchface.self, from: Data(with.utf8)).likesCount == 7)
        let face = try JSONDecoder().decode(Watchface.self, from: Data(without.utf8))
        #expect(face.likesCount == nil)
        #expect(face.thumbURL?.absoluteString == "https://fmc.tools/api/files/c/a/p.png?thumb=300x300")
    }
}
