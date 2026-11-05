module MoneyHelper
  COPPER_PER_GOLD = 10_000
  COPPER_PER_SILVER = 100
  # From here on, silver and copper are noise.
  GOLD_ONLY_FROM = 1_000

  # 12 po 34 pa 56 pc, leaving out what is zero.
  def money(copper)
    return "—" if copper.nil?

    gold = copper.fdiv(COPPER_PER_GOLD)
    return "#{number_with_delimiter(gold.round)} po" if gold >= GOLD_ONLY_FROM

    whole_gold, rest = copper.divmod(COPPER_PER_GOLD)
    silver, bronze = rest.divmod(COPPER_PER_SILVER)
    parts = { "po" => whole_gold, "pa" => silver, "pc" => bronze }
      .reject { |_, amount| amount.zero? }
      .map { |unit, amount| "#{amount} #{unit}" }
    parts.empty? ? "0 pc" : parts.join(" ")
  end

  # Shorter than `money`, for axes: a single unit, with at most two decimals.
  def axis_money(copper)
    return "0" if copper.zero?

    gold = copper.fdiv(COPPER_PER_GOLD)
    if gold >= 10_000
      "#{short_number(gold / 1_000)} k po"
    elsif gold >= 1
      "#{short_number(gold)} po"
    else
      "#{short_number(copper.fdiv(COPPER_PER_SILVER))} pa"
    end
  end

  def axis_count(value)
    return "#{short_number(value.fdiv(1_000))} k" if value >= 10_000

    short_number(value)
  end

  def short_number(value)
    number_with_precision(value, precision: 2, strip_insignificant_zeros: true, delimiter: " ")
  end

  # Prices have no good or bad direction, so this says which way and leaves it there.
  def price_change(now, before)
    return "—" if now.nil? || before.nil? || before.zero?

    change = (now - before).fdiv(before) * 100
    arrow, sign = if change.positive? then [ "↗", "+" ]
    elsif change.negative? then [ "↘", "−" ]
    else [ "→", "" ]
    end
    "#{arrow} #{sign}#{number_with_precision(change.abs, precision: 1)} %"
  end
end
