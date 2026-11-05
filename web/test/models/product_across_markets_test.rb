require "test_helper"

class ProductAcrossMarketsTest < ActiveSupport::TestCase
  setup do
    @hyjal = create_market
    @archimonde = create_market(connected_realm_id: 1302, name: "Archimonde")
    @american = create_market(region: "us", connected_realm_id: 1, name: "Aerie Peak")
    [ @hyjal, @archimonde, @american ].each { |market| create_snapshot(market, NOW) }
  end

  def across(item_id = 1, series = "", realm: nil) = ProductAcrossMarkets.new(@hyjal, item_id, series, realm: realm)

  test "compares the markets of a region, the cheapest first" do
    create_price(@hyjal, 1, NOW, min: 500)
    create_price(@archimonde, 1, NOW, min: 100)
    create_price(@american, 1, NOW, min: 1)

    assert_equal [ @archimonde.id, @hyjal.id ], across.rows.map(&:auction_house_id)
    assert across.comparable?
    assert across.current?(across.rows.last)
    assert_not across.current?(across.rows.first)
  end

  test "names each market by its realms, the reader's own first" do
    create_realm(@archimonde, name: "Archimonde")
    create_realm(@hyjal, name: "Hyjal")
    create_realm(@hyjal, name: "Elune")
    create_price(@hyjal, 1, NOW, min: 500)
    create_price(@archimonde, 1, NOW, min: 100)
    archimonde_row, hyjal_row = across.rows

    assert_equal [ "Archimonde" ], across.realms_of(archimonde_row).map(&:name)
    assert_equal [ "Elune", "Hyjal" ], across.realms_of(hyjal_row).map(&:name)

    mine = across(realm: Realm.find_by_route("eu", "hyjal"))
    assert_equal [ "Hyjal", "Elune" ], mine.realms_of(mine.rows.last).map(&:name)
    assert_equal [ "Archimonde" ], mine.realms_of(mine.rows.first).map(&:name)
  end

  test "has nothing to compare on a single market" do
    create_price(@hyjal, 1, NOW)
    create_price(@american, 1, NOW)

    assert_not across.comparable?
  end

  test "a caged pet is only compared to the same species" do
    create_price(@hyjal, 82800, NOW, variant: "pet:39")
    create_price(@archimonde, 82800, NOW, variant: "pet:40")

    assert_not across(82800, "pet:39").comparable?

    create_price(@archimonde, 82800, NOW, variant: "pet:39")

    assert across(82800, "pet:39").comparable?
  end

  test "keeps to a readable number of markets" do
    create_price(@hyjal, 1, NOW)
    (1..ProductAcrossMarkets::LIMIT + 2).each do |id|
      market = create_market(connected_realm_id: 5_000 + id, name: "Realm #{id}")
      create_snapshot(market, NOW)
      create_price(market, 1, NOW)
    end

    assert_equal ProductAcrossMarkets::LIMIT, across.rows.size
  end
end
