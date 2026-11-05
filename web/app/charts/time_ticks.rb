# Evenly spaced dates for a time axis, on round hours, days or months.
class TimeTicks
  def initialize(first, last)
    @first = first
    @last = last
  end

  def ticks
    return [ tick(@first) ] if @first == @last

    times.select { |time| time >= @first }.map { |time| tick(time) }
  end

  private

  def span = @last - @first

  def hourly? = span <= 1.5.days

  def times
    if hourly? then every(6.hours, from: next_multiple_of_six_hours)
    elsif span <= 10.days then every(1.day, from: @first.beginning_of_day)
    elsif span <= 100.days then every(1.week, from: @first.beginning_of_week)
    elsif span <= 400.days then every(1.month, from: @first.beginning_of_month)
    else every(3.months, from: @first.beginning_of_quarter)
    end
  end

  def next_multiple_of_six_hours
    hour = @first.beginning_of_hour
    hour += 1.hour until (hour.hour % 6).zero?
    hour
  end

  def every(step, from:)
    times = []
    current = from
    while current <= @last
      times << current
      current += step
    end
    times
  end

  def tick(time)
    { time: time, label: I18n.l(time, format: hourly? ? "%Hh" : "%-d %b") }
  end
end
