import Foundation
import Testing
@testable import AteKit

@Suite("Place map link")
struct PlaceMapLinkTests {
    private let smallWins = PlaceMapLink(
        name: "Small Wins", address: "1203 High St, Armadale VIC 3143, Australia",
        latitude: -37.8562109, longitude: 145.0278178, googlePlaceID: "ChIJH8uNX8Rp1moR3B6YRXsiNNc"
    )

    @Test func aGooglePlaceOpensOnItsPointAndListing() {
        #expect(smallWins.appleMapsURL.absoluteString
            == "https://maps.apple.com/?ll=-37.8562109,145.0278178&q=Small%20Wins")
        #expect(smallWins.googleMapsURL.absoluteString
            == "comgooglemapsurl://www.google.com/maps/search/?api=1&query=Small%20Wins"
                + "&query_place_id=ChIJH8uNX8Rp1moR3B6YRXsiNNc")
    }

    @Test func aHandAddedPlaceSearchesForItsNameAndAddress() {
        let hand = PlaceMapLink(name: "Corner Cafe", address: "12 Smith St, Fitzroy",
                                latitude: nil, longitude: nil, googlePlaceID: nil)
        #expect(hand.coordinate == nil)
        #expect(hand.appleMapsURL.absoluteString
            == "https://maps.apple.com/?q=Corner%20Cafe,%2012%20Smith%20St,%20Fitzroy")
        #expect(hand.googleMapsURL.absoluteString
            == "comgooglemapsurl://www.google.com/maps/search/?api=1&query=Corner%20Cafe,%2012%20Smith%20St,%20Fitzroy")
    }

    @Test func noAddressSearchesTheNameAlone() {
        let bare = PlaceMapLink(name: "Bar & Grill #2", address: "  ", latitude: nil, longitude: nil, googlePlaceID: "")
        #expect(bare.street == nil)
        #expect(bare.googlePlaceID == nil)
        #expect(bare.appleMapsURL.absoluteString == "https://maps.apple.com/?q=Bar%20%26%20Grill%20%232")
    }

    @Test func theAddressSplitsAfterItsFirstLine() {
        let lines = smallWins.addressLines
        #expect(lines?.first == "1203 High St")
        #expect(lines?.rest == "Armadale VIC 3143, Australia")
    }

    @Test func anAddressThatStartsWithTheNameSkipsIt() {
        let named = PlaceMapLink(name: "Small Wins", address: "Small Wins, 1203 High St, Armadale",
                                 latitude: nil, longitude: nil, googlePlaceID: nil)
        #expect(named.addressLines?.first == "1203 High St")
        #expect(named.addressLines?.rest == "Armadale")
    }

    @Test func aOneLineAddressHasNoSecondLine() {
        let one = PlaceMapLink(name: "X", address: "Phuket", latitude: nil, longitude: nil, googlePlaceID: nil)
        #expect(one.addressLines?.first == "Phuket")
        #expect(one.addressLines?.rest == nil)
        let none = PlaceMapLink(name: "X", address: " ", latitude: nil, longitude: nil, googlePlaceID: nil)
        #expect(none.addressLines == nil)
    }

    @Test func zeroZeroIsNoPoint() {
        let zero = PlaceMapLink(name: "X", address: nil, latitude: 0, longitude: 0, googlePlaceID: nil)
        #expect(zero.coordinate == nil)
        #expect(zero.appleMapsURL.absoluteString == "https://maps.apple.com/?q=X")
    }

    @Test func aPointWithoutAPlaceIDOpensGoogleOnThePoint() {
        let point = PlaceMapLink(name: "X", address: nil, latitude: -37.5, longitude: 145, googlePlaceID: nil)
        #expect(point.googleMapsURL.absoluteString
            == "comgooglemapsurl://www.google.com/maps/search/?api=1&query=-37.5000000,145.0000000")
    }

    @Test func theStreetIsTheAddressFirstLine() {
        #expect(smallWins.street == "1203 High St")
        let shop = PlaceMapLink(name: "Bali Hai", address: "Shop 2/32 Bourke St, Melbourne VIC 3000, Australia",
                                latitude: nil, longitude: nil, googlePlaceID: nil)
        #expect(shop.street == "Shop 2/32 Bourke St")
    }

    @Test func aSuburbLineOrAWordIsNoStreet() {
        let suburb = PlaceMapLink(name: "X", address: "Melbourne VIC 3000, Australia",
                                  latitude: nil, longitude: nil, googlePlaceID: nil)
        let word = PlaceMapLink(name: "X", address: "Fitzroy", latitude: nil, longitude: nil, googlePlaceID: nil)
        #expect(suburb.street == nil)
        #expect(word.street == nil)
    }

    @Test func aLandmarkIsNoStreetButTheNextLineCanBe() {
        let landmark = PlaceMapLink(name: "Roti MA Indy", address: "7-Eleven, Phuket 83000, Thailand",
                                    latitude: nil, longitude: nil, googlePlaceID: nil)
        #expect(landmark.street == nil)
        let next = PlaceMapLink(name: "Roti MA Indy", address: "7-Eleven, 12/3 Soi Bangla, Patong, Thailand",
                                latitude: nil, longitude: nil, googlePlaceID: nil)
        #expect(next.street == "12/3 Soi Bangla")
        let range = PlaceMapLink(name: "X", address: "12-14 Smith St, Fitzroy VIC 3065, Australia",
                                 latitude: nil, longitude: nil, googlePlaceID: nil)
        #expect(range.street == "12-14 Smith St")
    }

    @Test func theSummaryDecodesThePointAndIsFineWithout() throws {
        let id = UUID()
        let with = #"{"restaurant_id":"\#(id)","name":"Small Wins","#
            + #""lat":-37.85,"lng":145.02,"google_place_id":"ChIJx"}"#
        let without = #"{"restaurant_id":"\#(id)","name":"Small Wins"}"#
        let a = try JSONDecoder().decode(PlaceSummary.self, from: Data(with.utf8))
        let b = try JSONDecoder().decode(PlaceSummary.self, from: Data(without.utf8))
        #expect(PlaceMapLink(a).coordinate?.latitude == -37.85)
        #expect(a.googlePlaceID == "ChIJx")
        #expect(b.latitude == nil && b.googlePlaceID == nil)
    }
}
