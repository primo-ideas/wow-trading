# The plot area shared by every chart, in SVG user units, and its vertical scale.
class ChartFrame
  WIDTH = 960
  HEIGHT = 280
  LEFT = 76
  RIGHT = 150
  TOP = 12
  BOTTOM = 28

  def plot_left = LEFT
  def plot_right = WIDTH - RIGHT
  def plot_top = TOP
  def plot_bottom = HEIGHT - BOTTOM
  def plot_width = plot_right - plot_left
  def plot_height = plot_bottom - plot_top

  def view_box = "0 0 #{WIDTH} #{HEIGHT}"

  def y_ticks
    @y_ticks ||= self.class.ticks(*y_range, whole_numbers: whole_numbers?)
  end

  def y(value)
    low, high = y_ticks.minmax
    (plot_bottom - (value - low).fdiv(high - low) * plot_height).round(1)
  end

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
