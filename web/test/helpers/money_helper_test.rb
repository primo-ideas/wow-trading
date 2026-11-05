require "test_helper"

class MoneyHelperTest < ActionView::TestCase
  test "gives gold, silver and copper, leaving out zeros" do
    assert_equal "12g 34s 56c", money_text(123_456)
    assert_equal "1g", money_text(10_000)
    assert_equal "1g 5c", money_text(10_005)
    assert_equal "50s", money_text(5_000)
    assert_equal "7c", money_text(7)
    assert_equal "0c", money_text(0)
    assert_equal "—", money_text(nil)
  end

  test "large amounts are rounded to the gold" do
    assert_equal "1,234g", money_text(12_340_000)
    assert_equal "1,235g", money_text(12_345_678)
    assert_equal "1,000g", money_text(10_000_000)
    assert_equal "999g 99s 99c", money_text(9_999_999)
  end

  test "the parts carry each amount with its unit, for the chart script too" do
    assert_equal [ [ "12", "g" ], [ "34", "s" ] ], money_parts(123_400)
    assert_equal [ [ "—", nil ] ], money_parts(nil)
    assert_equal [ [ "0", "c" ] ], money_parts(0)
  end

  test "shows coins, with the amount spoken for screen readers" do
    html = Nokogiri::HTML5.fragment(money(123_456))

    assert_equal "12g 34s 56c", html.at_css(".money")["aria-label"]
    assert_equal "123456", html.text.delete(" ")
    assert_equal 3, html.css(".coin").size
    assert html.at_css(".coin-g")
    assert html.at_css(".coin-s")
    assert html.at_css(".coin-c")
  end

  test "a cell keeps a slot per coin, so that amounts line up" do
    html = Nokogiri::HTML5.fragment(money_cell(50_000))

    assert_equal 3, html.css(".money-slot").size
    assert_equal 1, html.css(".coin").size
  end

  test "a list keeps to two units at most, and to gold from a hundred" do
    assert_equal [ [ "564", "g" ] ], compact_money_parts(5_639_477)
    assert_equal [ [ "12", "g" ], [ "35", "s" ] ], compact_money_parts(123_456)
    assert_equal [ [ "12", "g" ] ], compact_money_parts(120_049)
    assert_equal [ [ "34", "s" ], [ "56", "c" ] ], compact_money_parts(3_456)
    assert_equal [ [ "7", "c" ] ], compact_money_parts(7)
    assert_equal [ [ "0", "c" ] ], compact_money_parts(0)
  end

  test "rounding up to the next unit does not leave an impossible amount" do
    assert_equal [ [ "13", "g" ] ], compact_money_parts(129_999)
    assert_equal [ [ "100", "g" ] ], compact_money_parts(999_999)
  end

  test "a cell keeps the exact amount for those who want it" do
    html = Nokogiri::HTML5.fragment(money_cell(5_639_477))

    assert_equal "563g 94s 77c", html.at_css(".money")["title"]
    assert_equal "563g 94s 77c", html.at_css(".money")["aria-label"]
    assert_equal "564", html.text.strip
  end

  test "a column only makes room for the units its amounts use" do
    assert_equal [ "g" ], money_units([ 12_340_000, 5_639_477, nil ])
    assert_equal %w[g s], money_units([ 12_340_000, 123_456 ])
    assert_equal %w[g s c], money_units([ 12_340_000, 3_456 ])
    assert_equal [], money_units([ nil ])

    html = Nokogiri::HTML5.fragment(money_cell(5_000_000, units: [ "g" ]))
    assert_equal 1, html.css(".money-slot").size
  end

  test "each unit stays together with its coin" do
    html = Nokogiri::HTML5.fragment(money(123_456))

    assert_equal [ "12", "34", "56" ], html.css(".money-part").map(&:text)
    assert_equal 3, html.css(".money-part .coin").size
  end

  test "a missing price is a dash" do
    assert_includes money(nil), "—"
    assert_includes money_cell(nil), "—"
  end

  test "axes use a single unit" do
    assert_equal "0", axis_money(0)
    assert_equal "50", text_of(axis_money(5_000))
    assert axis_money(5_000).include?("coin-s")
    assert_equal "1.5", text_of(axis_money(15_000))
    assert axis_money(15_000).include?("coin-g")
    assert_equal "120", text_of(axis_money(1_200_000))
    assert_equal "15k", text_of(axis_money(150_000_000))
  end

  test "counts shorten from ten thousand" do
    assert_equal "9,500", axis_count(9_500)
    assert_equal "12k", axis_count(12_000)
  end

  test "changes say which way, in words and in class" do
    assert_equal "↗ +10.0%", change_text(0.1)
    assert_equal "↘ −10.0%", change_text(-0.1)
    assert_equal "→ 0.0%", change_text(0)
    assert_equal "—", change_text(nil)
    assert_includes change_pill(0.1), "up"
    assert_includes change_pill(-0.1), "down"
    assert_includes change_pill(0), "flat"
    assert_includes change_pill(nil), "flat"
  end

  test "a change too small to show as one reads as none" do
    assert_equal "→ 0.0%", change_text(0.0004)
  end

  test "a change needs both prices" do
    assert_in_delta 0.1, change_between(1_100, 1_000)
    assert_nil change_between(nil, 1_000)
    assert_nil change_between(1_000, nil)
    assert_nil change_between(1_000, 0)
  end

  private

  def text_of(html) = Nokogiri::HTML5.fragment(html).text
end
