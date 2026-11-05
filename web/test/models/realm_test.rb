require "test_helper"

class RealmTest < ActiveSupport::TestCase
  setup do
    @market = create_market(name: "Archimonde / Naxxramas")
    @commodities = create_commodities
    @realm = create_realm(@market, name: "Archimonde")
  end

  test "reads its own market and the commodities of its region, not those of another" do
    create_commodities(region: "us")

    assert_equal [ @market, @commodities ], @realm.markets
  end

  test "can be picked once its market, or the commodities of its region, are followed" do
    american = create_realm(create_market(region: "us", connected_realm_id: 1, name: "Aerie Peak"), name: "Aerie Peak")
    assert_empty Realm.followed(AuctionHouse.tracked.to_a)

    create_snapshot(@market, NOW)
    assert_equal [ @realm ], Realm.followed(AuctionHouse.tracked.to_a).to_a

    ghost = create_realm(create_market(connected_realm_id: 77, name: "Ghost"), name: "Ghost")
    create_snapshot(@commodities, NOW)
    assert_equal [ @realm, ghost ], Realm.followed(AuctionHouse.tracked.to_a).to_a
    assert_not_includes Realm.followed(AuctionHouse.tracked.to_a), american
  end

  test "finds the market an item trades on, its own by default" do
    create_snapshot(@market, NOW)
    create_snapshot(@commodities, NOW)
    create_price(@commodities, 2770, NOW)
    create_price(@market, 2589, NOW - 1.hour)

    assert_equal @commodities, @realm.market_of(2770)
    assert_equal @market, @realm.market_of(2589)
    assert_equal @market, @realm.market_of(123)
  end

  test "is as fresh as its market that lags behind, and has no date before any snapshot" do
    assert_nil @realm.latest_taken_at

    create_snapshot(@market, NOW)
    create_snapshot(@commodities, NOW - 2.hours)

    assert_equal NOW - 2.hours, Realm.find_by_route("eu", "archimonde").latest_taken_at
  end

  test "knows whether its own market is followed" do
    create_snapshot(@commodities, NOW)
    assert_not @realm.own_market_followed?

    create_snapshot(@market, NOW)
    assert Realm.find_by_route("eu", "archimonde").own_market_followed?
  end

  test "is found by its address, accents included, and nothing else" do
    create_realm(@market, name: "Festung der Stürme", slug: "festung-der-stürme")

    assert_equal "Festung der Stürme", Realm.find_by_route("eu", "festung-der-stürme").name
    assert_nil Realm.find_by_route("us", "archimonde")
    assert_nil Realm.find_by_route(nil, nil)
  end
end
