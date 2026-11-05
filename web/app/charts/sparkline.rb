# A tiny curve without axes, in a box of its own size: only its shape matters.
class Sparkline
  WIDTH = 88
  HEIGHT = 26
  PADDING = 4

  def initialize(values)
    @values = values
  end

  def drawable? = @values.size >= 2

  def view_box = "0 0 #{WIDTH} #{HEIGHT}"

  def line_path = "M#{coordinates.map { |x, y| "#{x} #{y}" }.join("L")}"

  def area_path = "#{line_path}L#{coordinates.last.first} #{HEIGHT}L#{coordinates.first.first} #{HEIGHT}Z"

  def end_point = coordinates.last

  def direction
    return "flat" if @values.last == @values.first

    @values.last > @values.first ? "up" : "down"
  end

  private

  def coordinates
    @coordinates ||= begin
      low, high = @values.minmax
      spread = (high - low).nonzero? || 1
      last = (@values.size - 1).to_f
      @values.each_with_index.map do |value, index|
        [
          (PADDING + index / last * (WIDTH - 2 * PADDING)).round(1),
          (HEIGHT - PADDING - (value - low) / spread.to_f * (HEIGHT - 2 * PADDING)).round(1)
        ]
      end
    end
  end
end
