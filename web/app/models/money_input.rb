# An amount as a player types it, in copper: "12g 50s", "12g50s3c", "1,234g", or a plain
# number of gold, "12.5" or "12,5". Anything else is nil, and so is zero.
module MoneyInput
  COPPER = { "g" => 10_000, "s" => 100, "c" => 1 }.freeze
  # Far above anything sold, and well within a bigint.
  MAX = 10**12
  COINS = /\A(?:(\d+)g)?(?:(\d+)s)?(?:(\d+)c)?\z/
  GOLD = /\A(\d{1,8})(?:[.,](\d{1,4}))?\z/

  module_function

  def parse(text)
    text = text.to_s.downcase.gsub(/[[:space:]]/, "")
    return if text.empty? || text.length > 30

    copper = if text.match?(/[gsc]/)
      coins(text.delete(","))
    elsif (match = text.match(GOLD))
      gold = match[1].to_r + (match[2] ? "0.#{match[2]}".to_r : 0)
      (gold * COPPER["g"]).round
    end
    copper if copper&.positive? && copper <= MAX
  end

  def coins(text)
    match = text.match(COINS)
    return unless match && match.captures.any?

    match.captures.zip(COPPER.values).sum { |amount, unit| amount.to_i * unit }
  end
end
