require "test_helper"

class SalesRhythmTest < ActiveSupport::TestCase
  # A Monday, 14:21 in Paris.
  LATEST = Time.utc(2026, 11, 2, 13, 21)

  setup do
    @market = create_market
    create_item(2589)
  end

  def rhythm(series = "", latest: LATEST) = SalesRhythm.new(@market, 2589, series, latest)

  def snapshots_over(days)
    (0..days * 24).each { |hours| create_snapshot(@market, LATEST - hours.hours) }
  end

  test "averages the units sold in each hour of the day, Paris time, over the days covered" do
    snapshots_over(4)
    # Snapshots at 14:21 Paris count what sold since 13:21: the 13:00 hour.
    [ 0, 1, 2, 3 ].each { |day| create_sale(@market, 2589, LATEST - day.days, quantity: 3, value: 300) }
    create_sale(@market, 2589, LATEST - 5.hours, quantity: 8, value: 1_600)

    hours = rhythm.hours

    assert_in_delta 4.0, rhythm.days
    assert_equal 24, hours.size
    assert_in_delta 3.0, hours[13].quantity
    assert_equal 100, hours[13].price
    assert_in_delta 2.0, hours[8].quantity
    assert_equal 200, hours[8].price
    assert_in_delta 0.0, hours[20].quantity
    assert_nil hours[20].price
    assert_equal "13:00", rhythm.best_hour.label
  end

  test "averages each day of the week over the times it came" do
    snapshots_over(13)
    (0..13).each { |day| create_sale(@market, 2589, LATEST - day.days, quantity: day.zero? || day == 7 ? 10 : 1) }

    assert rhythm.weekdays?
    assert_equal "Monday", rhythm.best_weekday.label
    assert_in_delta 10.0, rhythm.weekdays.first.quantity
    assert_in_delta 1.0, rhythm.weekdays.last.quantity
  end

  test "adds up the variants of gear, and keeps each caged pet apart" do
    snapshots_over(2)
    create_sale(@market, 2589, LATEST, quantity: 3, variant: "bonus:1")
    create_sale(@market, 2589, LATEST, quantity: 5, variant: "bonus:2")
    create_sale(@market, 2589, LATEST, quantity: 7, variant: "pet:39")

    assert_in_delta 4.0, rhythm.hours[13].quantity
    assert_in_delta 3.5, rhythm("pet:39").hours[13].quantity
    assert_not rhythm("pet:40").sold?
  end

  test "says nothing before enough history" do
    snapshots_over(1)
    create_sale(@market, 2589, LATEST)

    assert rhythm.sold?
    assert_not rhythm.hours?
    assert_not rhythm.weekdays?
    assert_not rhythm(latest: nil).sold?
  end

  test "leaves out sales older than two weeks" do
    snapshots_over(20)
    create_sale(@market, 2589, LATEST - 15.days, quantity: 100)

    assert_not rhythm.sold?
  end
end
