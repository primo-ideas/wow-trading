require "test_helper"

class ItemHistoryTest < ActiveSupport::TestCase
  setup do
    @market = create_market
    @item = create_item(2589)
    create_snapshot(@market, NOW)
  end

  test "a period ends at the latest snapshot, not now" do
    create_price(@market, 2589, NOW - 6.days)
    create_price(@market, 2589, NOW - 8.days)

    assert_equal [ NOW - 6.days ], history(period: "7j").prices.map(&:taken_at)
  end

  test "an unknown period falls back to the default" do
    assert_equal ItemHistory::DEFAULT_PERIOD, history(period: "1000j").period
  end

  test "joins rolled up days and hourly detail in time order" do
    insert_daily_price(@market, 2589, (NOW - 20.days).to_date, median: 500)
    create_price(@market, 2589, NOW - 1.hour, median: 1_000)
    create_price(@market, 2589, NOW, median: 1_100)

    prices = history(period: "tout").prices

    assert_equal [ 500, 1_000, 1_100 ], prices.map(&:median_price)
    assert_equal [ true, false, false ], prices.map(&:daily)
    assert_equal Time.utc(2026, 10, 16, 12), prices.first.taken_at
  end

  test "a period leaves out rolled up days before it" do
    insert_daily_price(@market, 2589, (NOW - 20.days).to_date, median: 500)
    insert_daily_price(@market, 2589, (NOW - 40.days).to_date, median: 400)

    assert_equal [ 500 ], history(period: "30j").prices.map(&:median_price)
  end

  test "keeps variants and markets apart" do
    other = create_market(connected_realm_id: 2, name: "Autre")
    create_price(@market, 2589, NOW, median: 100, variant: "pet:39")
    create_price(@market, 2589, NOW, median: 200, variant: "pet:40")
    create_price(other, 2589, NOW, median: 300, variant: "pet:39")

    prices = history(variant: "pet:39").prices

    assert_equal [ 100 ], prices.map(&:median_price)
  end

  test "sales over a day are hourly, with empty hours kept" do
    create_sale(@market, 2589, NOW, quantity: 3, value: 30)
    create_sale(@market, 2589, NOW - 2.hours, quantity: 5, value: 50)

    sales = history(period: "24h").sales

    assert_equal 25, sales.size
    assert_equal [ 5, 0, 3 ], sales.last(3).map(&:sold_quantity)
    assert sales.all?(&:hourly?)
  end

  test "sales over a longer period add up per UTC day" do
    create_sale(@market, 2589, Time.utc(2026, 11, 5, 1), quantity: 3, value: 30)
    create_sale(@market, 2589, Time.utc(2026, 11, 5, 11), quantity: 4, value: 40)
    create_sale(@market, 2589, Time.utc(2026, 11, 4, 23), quantity: 5, value: 50)

    sales = history(period: "7j").sales

    assert_equal 8, sales.size
    assert_equal [ Time.utc(2026, 11, 4), Time.utc(2026, 11, 5) ], sales.last(2).map(&:starts_at)
    assert_equal [ 5, 7 ], sales.last(2).map(&:sold_quantity)
    assert_equal 70, sales.last.sold_value
    assert_not sales.first.hourly?
  end

  test "rolled up sales join the same days" do
    insert_daily_sale(@market, 2589, Date.new(2026, 10, 1), quantity: 9, value: 90)
    create_sale(@market, 2589, NOW, quantity: 1, value: 10)

    sales = history(period: "tout").sales

    assert_equal Time.utc(2026, 10, 1), sales.first.starts_at
    assert_equal 9, sales.first.sold_quantity
    assert_equal 1, sales.last.sold_quantity
    assert_equal 36, sales.size
  end

  test "all time without any sale has no bucket" do
    assert_empty history(period: "tout").sales
  end

  test "current and reference come from the latest snapshot and a day before" do
    create_price(@market, 2589, NOW, median: 1_100)
    create_price(@market, 2589, NOW - 1.day, median: 1_000)

    assert_equal 1_100, history.current.median_price
    assert_equal 1_000, history.reference.median_price
  end

  test "an item no longer on sale has no current point" do
    create_price(@market, 2589, NOW - 1.hour)

    assert_nil history.current
    assert_equal 1, history.prices.size
  end

  test "counts what sold over the last day" do
    create_sale(@market, 2589, NOW, quantity: 3)
    create_sale(@market, 2589, NOW - 2.days, quantity: 100)

    assert_equal 3, history.sold_last_day
  end

  test "a market without a snapshot has nothing" do
    market = create_market(connected_realm_id: 2, name: "Vide")
    empty = ItemHistory.new(market, @item, variant: "")

    assert_nil empty.current
    assert_nil empty.reference
    assert_empty empty.prices
    assert_empty empty.sales
    assert_equal 0, empty.sold_last_day
  end

  private

  def history(variant: "", period: nil)
    ItemHistory.new(@market, @item, variant: variant, period: period)
  end
end
