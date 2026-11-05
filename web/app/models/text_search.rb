# Case and accent insensitive matching, so that "etoffe" finds "Étoffe".
#
# ILIKE cannot do this: the database uses the C locale, where it only folds ASCII,
# and removing accents properly would take an extension in a schema this app does
# not own.
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
  # translate() maps these two strings character by character.
  ACCENTED = ACCENTS.values.join.freeze
  PLAIN = ACCENTS.map { |plain, accented| plain * accented.length }.join.freeze

  module_function

  # SQL for `column` containing the bind `:query`, given to `pattern`.
  def condition(column)
    "#{normalized(column)} LIKE #{normalized(":query")}"
  end

  def pattern(query)
    "%#{ActiveRecord::Base.sanitize_sql_like(query)}%"
  end

  def normalized(expression)
    %(translate(lower(#{expression} COLLATE "und-x-icu"), '#{ACCENTED}', '#{PLAIN}'))
  end
end
