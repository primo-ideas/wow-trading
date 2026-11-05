require "test_helper"

class ItemSearchTest < ActiveSupport::TestCase
  setup do
    @realm = create_market
    @commodities = create_market(connected_realm_id: nil, name: "Commodities")
    create_snapshot(@realm, NOW)
    create_snapshot(@commodities, NOW)
    create_item(1, name: "Copper Ore")
    create_item(2, name: "Pure Copper Shard")
    create_item(3, name: "Éclair")
  end

  def results(query, markets = [ @realm, @commodities ])
    ItemSearch.new(query, markets).results
  end

  test "finds what is on sale on the given markets, without regard for accents" do
    create_price(@commodities, 1, NOW)
    create_price(@realm, 3, NOW)

    assert_equal [ 1 ], results("copper").map(&:item_id)
    assert_equal [ 3 ], results("ECLAIR").map(&:item_id)
  end

  test "tells what kind of item a result is" do
    create_item(4, name: "Copper Bar", item_class: "Tradeskill", item_subclass: "Metal & Stone")
    create_price(@commodities, 4, NOW)

    result = results("copper bar").first

    assert_equal [ "Tradeskill", "Metal & Stone" ], [ result.item_class, result.item_subclass ]
  end

  test "leaves out what is not on sale, or on another market" do
    other = create_market(connected_realm_id: 9, name: "Other")
    create_snapshot(other, NOW)
    create_price(other, 1, NOW)

    assert_empty results("copper")
  end

  test "leaves out what was on sale at an older snapshot only" do
    create_price(@commodities, 1, NOW - 1.hour)

    assert_empty results("copper")
  end

  test "names starting with the search come first" do
    create_price(@commodities, 1, NOW, quantity: 1)
    create_price(@commodities, 2, NOW, quantity: 999)

    assert_equal [ 1, 2 ], results("copper").map(&:item_id)
  end

  test "among equals, what is most available comes first" do
    create_item(4, name: "Copper Bar")
    create_price(@commodities, 1, NOW, quantity: 1)
    create_price(@commodities, 4, NOW, quantity: 999)

    assert_equal [ 4, 1 ], results("copper").map(&:item_id)
  end

  test "finds a caged pet by its species" do
    create_item(82800, name: "Pet Cage")
    create_pet(39, name: "Mechanical Squirrel")
    create_price(@realm, 82800, NOW, variant: "pet:39")

    result = results("squirrel").first

    assert_equal "pet:39", result.variant_param
    assert_equal "Mechanical Squirrel", result.display_name
  end

  test "gear appears once, from its cheapest variant" do
    create_price(@realm, 3, NOW, min: 900, variant: "bonus:1")
    create_price(@realm, 3, NOW, min: 100, variant: "bonus:2")

    result = results("eclair").first

    assert_equal 100, result.min_price
    assert result.several_variants?
    assert_nil result.variant_param
  end

  test "a search that is too short does not run" do
    create_price(@commodities, 1, NOW)

    search = ItemSearch.new(" c ", [ @commodities ])

    assert_not search.searchable?
    assert_empty search.results
  end

  test "wildcards are taken literally, and nothing reaches the database unescaped" do
    create_price(@commodities, 1, NOW)

    assert_empty results("%%")
    assert_empty results("'; DROP TABLE items; --")
    assert Item.exists?(1)
  end

  test "what is typed and what is stored lose their accents the same way" do
    create_item(5, name: "ÀÉÎÕÛ çñÿœæ")
    create_price(@realm, 5, NOW)

    assert_equal [ 5 ], results("aeiou cnyoa").map(&:item_id)
    assert_equal [ 5 ], results("àéîõû çñÿœæ").map(&:item_id)

    sql = Dir[FetcherSchema::MIGRATIONS.to_s].map { |file| File.read(file) }.join
    assert sql.include?("'#{TextSearch::ACCENTED}'"), "the migrations must list the same accents"
    assert sql.include?("'#{TextSearch::PLAIN}'"), "the migrations must map them to the same letters"
  end

  test "a market without a snapshot, or no market at all, finds nothing" do
    empty = create_market(connected_realm_id: 8, name: "Empty")

    assert_empty results("copper", [ empty ])
    assert_empty results("copper", [])
  end
end
