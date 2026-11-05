# Case and accent insensitive matching, so that "eclair" finds "Éclair": against
# `search_name`, which `items` and `pets` store without case or accents.
module TextSearch
  ACCENTS = {
    "a" => "àáâãäåæ",
    "c" => "ç",
    "e" => "èéêë",
    "i" => "ìíîï",
    "n" => "ñ",
    "o" => "òóôõöøœ",
    "u" => "ùúûü",
    "y" => "ýÿ"
  }.freeze
  # translate() maps these two strings character by character. The fetcher's migrations
  # hold the same two strings, for what the columns store.
  ACCENTED = ACCENTS.values.join.freeze
  PLAIN = ACCENTS.map { |plain, accented| plain * accented.length }.join.freeze

  module_function

  # SQL for a stored `column` matching a bind, by default `:query`, given to `pattern`.
  def condition(column, bind: ":query")
    %(#{column} LIKE translate(lower(#{bind} COLLATE "und-x-icu"), '#{ACCENTED}', '#{PLAIN}'))
  end

  def pattern(query) = "%#{escape(query)}%"

  def escape(query) = ActiveRecord::Base.sanitize_sql_like(query)
end
