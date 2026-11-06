require "test_helper"

class MoneyInputTest < ActiveSupport::TestCase
  test "reads amounts as the game writes them" do
    assert_equal 125_000, MoneyInput.parse("12g 50s")
    assert_equal 125_003, MoneyInput.parse("12g50s3c")
    assert_equal 50, MoneyInput.parse("50c")
    assert_equal 1_234_0000, MoneyInput.parse("1,234g")
    assert_equal 120_000, MoneyInput.parse(" 12 G ")
  end

  test "reads a plain number as gold, with a point or a comma" do
    assert_equal 120_000, MoneyInput.parse("12")
    assert_equal 125_000, MoneyInput.parse("12.5")
    assert_equal 125_000, MoneyInput.parse("12,5")
    assert_equal 1, MoneyInput.parse("0.0001")
  end

  test "reads back what the site writes" do
    helper = Object.new.extend(ActionView::Helpers::NumberHelper, MoneyHelper)

    # From 1,000 gold on, the site shows whole gold only.
    [ 1, 99, 125_003, 9_999_999, 12_345_670_000 ].each do |copper|
      assert_equal copper, MoneyInput.parse(helper.money_text(copper)), helper.money_text(copper)
    end
  end

  test "is nil for anything else, zero included" do
    [ nil, "", " ", "0", "0g", "abc", "12x", "g", "12g 50", "1.2.3", "-5", "12s 3g", "1" * 40, "99999999999g" ].each do |text|
      assert_nil MoneyInput.parse(text), text.inspect
    end
  end
end
