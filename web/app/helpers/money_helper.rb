# Prices as the game shows them: gold, silver and copper coins.
module MoneyHelper
  COPPER_PER_GOLD = 10_000
  COPPER_PER_SILVER = 100
  # From here on, silver and copper are noise.
  GOLD_ONLY_FROM = 1_000
  COMPACT_GOLD_ONLY_FROM = 100
  UNIT_NAMES = { "g" => "po", "s" => "pa", "c" => "pc" }.freeze

  # [text, unit] pairs, leaving out what is zero. For the chart script as well, so that
  # these rules are only written here.
  def money_parts(copper)
    return [ [ "—", nil ] ] if copper.nil?

    gold = copper.fdiv(COPPER_PER_GOLD)
    return [ [ number_with_delimiter(gold.round), "g" ] ] if gold >= GOLD_ONLY_FROM

    whole_gold, rest = copper.to_i.divmod(COPPER_PER_GOLD)
    silver, bronze = rest.divmod(COPPER_PER_SILVER)
    parts = [ [ whole_gold, "g" ], [ silver, "s" ], [ bronze, "c" ] ]
      .reject { |amount, _| amount.zero? }
      .map { |amount, unit| [ amount.to_s, unit ] }
    parts.empty? ? [ [ "0", "c" ] ] : parts
  end

  # 12 po 34 pa 56 pc
  def money_text(copper)
    money_parts(copper).map { |text, unit| [ text, UNIT_NAMES[unit] ].compact.join(" ") }.join(" ")
  end

  def money(copper)
    return tag.span("—", class: "money") if copper.nil?

    tag.span(class: "money", role: "img", "aria-label": money_text(copper)) do
      safe_join(money_parts(copper).map { |text, unit| tag.span(coin_amount(text, unit), class: "money-part") })
    end
  end

  # What a list needs to compare prices: two units at most, and only gold once there is
  # enough of it. The exact amount stays in the title, and on the product's page.
  def compact_money_parts(copper)
    if copper >= COMPACT_GOLD_ONLY_FROM * COPPER_PER_GOLD
      [ [ number_with_delimiter(copper.fdiv(COPPER_PER_GOLD).round), "g" ] ]
    elsif copper >= COPPER_PER_GOLD
      money_parts(copper.fdiv(COPPER_PER_SILVER).round * COPPER_PER_SILVER)
    else
      money_parts(copper)
    end
  end

  # The units a column of amounts needs. A column all in gold then keeps no empty slots,
  # which would leave its figures short of the right edge, away from their header.
  def money_units(amounts)
    used = amounts.compact.flat_map { |copper| compact_money_parts(copper).map(&:last) }
    UNIT_NAMES.keys & used
  end

  # For columns of prices: one slot per unit, so that coins line up from row to row.
  def money_cell(copper, units: UNIT_NAMES.keys)
    return tag.span("—", class: "money") if copper.nil?

    parts = compact_money_parts(copper).to_h { |text, unit| [ unit, text ] }
    exact = money_text(copper)
    tag.span(class: "money money-cell", role: "img", "aria-label": exact, title: exact) do
      safe_join(units.map { |unit|
        tag.span(parts[unit] ? coin_amount(parts[unit], unit) : "", class: "money-slot")
      })
    end
  end

  # Shorter, for axes: a single unit, with at most two decimals.
  def axis_money(copper)
    return "0" if copper.zero?

    gold = copper.fdiv(COPPER_PER_GOLD)
    if gold >= 10_000 then coin_amount("#{short_number(gold / 1_000)} k", "g")
    elsif gold >= 1 then coin_amount(short_number(gold), "g")
    else coin_amount(short_number(copper.fdiv(COPPER_PER_SILVER)), "s")
    end
  end

  def axis_count(value)
    return "#{short_number(value.fdiv(1_000))} k" if value >= 10_000

    short_number(value)
  end

  def count_parts(value) = [ [ number_with_delimiter(value), nil ] ]

  def short_number(value)
    number_with_precision(value, precision: 2, strip_insignificant_zeros: true, delimiter: " ")
  end

  # Below 1 %, a change reads as a change that did not happen.
  def change_class(fraction)
    return "flat" if fraction.nil? || fraction.abs < 0.0005

    fraction.positive? ? "up" : "down"
  end

  def change_text(fraction)
    return "—" if fraction.nil?

    arrow, sign = case change_class(fraction)
    when "up" then [ "↗", "+" ]
    when "down" then [ "↘", "−" ]
    else [ "→", "" ]
    end
    "#{arrow} #{sign}#{number_with_precision(fraction.abs * 100, precision: 1)} %"
  end

  def change_pill(fraction)
    tag.span(change_text(fraction), class: "change #{change_class(fraction)}")
  end

  def change_between(now, before)
    return if now.nil? || before.nil? || before.zero?

    (now - before).fdiv(before)
  end

  private

  def coin_amount(text, unit)
    safe_join([ text, tag.i("", class: "coin coin-#{unit}", "aria-hidden": "true") ])
  end
end
