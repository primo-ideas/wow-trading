require "test_helper"

class MoneyHelperTest < ActionView::TestCase
  test "gives gold, silver and copper, leaving out zeros" do
    assert_equal "12 po 34 pa 56 pc", money(123_456)
    assert_equal "1 po", money(10_000)
    assert_equal "1 po 5 pc", money(10_005)
    assert_equal "50 pa", money(5_000)
    assert_equal "7 pc", money(7)
    assert_equal "0 pc", money(0)
    assert_equal "—", money(nil)
  end

  test "large amounts are rounded to the gold" do
    assert_equal "1#{delimiter}234 po", money(12_340_000)
    assert_equal "1#{delimiter}235 po", money(12_345_678)
    assert_equal "1#{delimiter}000 po", money(10_000_000)
    assert_equal "999 po 99 pa 99 pc", money(9_999_999)
  end

  test "axes use a single unit" do
    assert_equal "0", axis_money(0)
    assert_equal "50 pa", axis_money(5_000)
    assert_equal "1,5 po", axis_money(15_000)
    assert_equal "120 po", axis_money(1_200_000)
    assert_equal "15 k po", axis_money(150_000_000)
  end

  test "counts shorten from ten thousand" do
    assert_equal "9 500", axis_count(9_500)
    assert_equal "12 k", axis_count(12_000)
  end

  test "price changes say which way" do
    assert_equal "↗ +10,0 %", price_change(1_100, 1_000)
    assert_equal "↘ −10,0 %", price_change(900, 1_000)
    assert_equal "→ 0,0 %", price_change(1_000, 1_000)
  end

  test "a price change needs both prices" do
    assert_equal "—", price_change(nil, 1_000)
    assert_equal "—", price_change(1_000, nil)
    assert_equal "—", price_change(1_000, 0)
  end

  private

  def delimiter = I18n.t("number.format.delimiter")
end
