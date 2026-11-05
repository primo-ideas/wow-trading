# The vertical scale shared by every chart. Positions are percentages of the plot, so
# that the page lays a chart out at any width while its text keeps its size.
class ChartFrame
  def y_ticks
    @y_ticks ||= self.class.ticks(*y_range, whole_numbers: whole_numbers?)
  end

  # From the top of the plot.
  def y(value)
    low, high = y_ticks.minmax
    (100 - (value - low).fdiv(high - low) * 100).round(2)
  end

  def y_labels
    y_ticks.map { |value| { y: y(value), label: @format_axis.call(value) } }
  end

  def whole_numbers? = false

  # Round values covering `low` to `high`, spread over about `count` ticks. Half a
  # sold item makes no sense, hence `whole_numbers` for what is counted.
  def self.ticks(low, high, count: 5, whole_numbers: false)
    low = low.to_f
    high = high.to_f
    if low == high
      padding = low.zero? ? 1.0 : low.abs * 0.1
      low -= padding
      high += padding
    end

    step = round_step((high - low) / (count - 1))
    step = [ step, 1.0 ].max if whole_numbers
    ((low / step).floor..(high / step).ceil).map { |index| index * step }
  end

  def self.round_step(rough)
    magnitude = 10.0**Math.log10(rough).floor
    fraction = rough / magnitude
    multiple = if fraction <= 1 then 1
    elsif fraction <= 2 then 2
    elsif fraction <= 5 then 5
    else 10
    end
    multiple * magnitude
  end
end
