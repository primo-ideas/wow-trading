# One series of columns growing from zero, one per bucket of time.
#
# `rows` are hashes holding :value, :title for the tooltip, :tick for the axis, and
# :details, a list of [name, formatted value] pairs for the tooltip and the table.
class ColumnChart < ChartFrame
  MAX_THICKNESS = 24
  GAP = 2
  RADIUS = 4
  MAX_X_LABELS = 8
  # A small value next to a huge one must not look like no value at all.
  MIN_HEIGHT = 1

  def initialize(rows:, format_axis:)
    @rows = rows
    @format_axis = format_axis
  end

  def empty? = @rows.empty?

  def whole_numbers? = true

  # Columns at zero draw nothing, but keep their place in the tooltip.
  def columns
    @rows.each_with_index.filter_map do |row, index|
      { index: index, path: column_path(index, row[:value]) } unless row[:value].zero?
    end
  end

  def y_labels
    y_ticks.map { |value| { y: y(value), label: @format_axis.call(value) } }
  end

  def x_labels
    every = [ (@rows.size.to_f / MAX_X_LABELS).ceil, 1 ].max
    @rows.each_with_index.filter_map do |row, index|
      { x: center(index), label: row[:tick] } if (index % every).zero?
    end
  end

  def points
    @rows.each_with_index.map do |row, index|
      {
        x: center(index),
        title: row[:title],
        rows: row[:details].map { |name, value| { name: name, css_class: "series-1", value: value } }
      }
    end
  end

  def table_columns = @rows.first[:details].map(&:first)

  def table_rows
    @rows.reverse.map { |row| [ row[:title], *row[:details].map(&:last) ] }
  end

  private

  def slot = plot_width.fdiv(@rows.size)

  def center(index) = (plot_left + (index + 0.5) * slot).round(1)

  def thickness = (slot - GAP).clamp(1, MAX_THICKNESS)

  # Rounded at the data end, square on the baseline.
  def column_path(index, value)
    left = (center(index) - thickness / 2).round(1)
    right = (left + thickness).round(1)
    base = y(0)
    top = [ y(value), base - MIN_HEIGHT ].min
    radius = [ RADIUS, thickness / 2, base - top ].min.round(1)
    "M#{left} #{base}V#{(top + radius).round(1)}Q#{left} #{top} #{(left + radius).round(1)} #{top}" \
      "H#{(right - radius).round(1)}Q#{right} #{top} #{right} #{(top + radius).round(1)}V#{base}Z"
  end

  def y_range = [ 0, [ @rows.map { |row| row[:value] }.max, 1 ].max ]
end
