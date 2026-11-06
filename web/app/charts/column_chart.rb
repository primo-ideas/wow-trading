# One series of columns growing from zero, one per bucket of time.
#
# `rows` are hashes holding :value, :time, :title for the tooltip, :tick for the axis,
# and :details, a list of [name, parts for the tooltip, cell for the table]. Buckets
# that recur, like the hours of a day, list their table in order rather than newest first.
class ColumnChart < ChartFrame
  MAX_X_LABELS = 8

  def initialize(rows:, format_axis:, newest_first: true, max_x_labels: MAX_X_LABELS)
    @rows = rows
    @format_axis = format_axis
    @newest_first = newest_first
    @max_x_labels = max_x_labels
  end

  def empty? = @rows.empty?

  def whole_numbers? = true

  # Every bucket, with the height of its column. Zero draws nothing.
  def slots
    @rows.each_with_index.map do |row, index|
      { index: index, height: row[:value].zero? ? nil : (100 - y(row[:value])).round(2) }
    end
  end

  def x_labels
    every = [ (@rows.size.to_f / @max_x_labels).ceil, 1 ].max
    @rows.each_with_index.filter_map do |row, index|
      { x: center(index), label: row[:tick] } if (index % every).zero?
    end
  end

  def points
    @rows.each_with_index.map do |row, index|
      {
        x: center(index),
        t: row[:time].to_i,
        title: row[:title],
        rows: row[:details].map { |name, parts, _cell| { name: name, css_class: "series-1", parts: parts } }
      }
    end
  end

  def table_columns = @rows.first[:details].map(&:first)

  def table_rows
    (@newest_first ? @rows.reverse : @rows).map { |row| [ row[:title], *row[:details].map(&:last) ] }
  end

  private

  def center(index) = ((index + 0.5) / @rows.size * 100).round(2)

  def y_range = [ 0, [ @rows.map { |row| row[:value] }.max, 1 ].max ]
end
