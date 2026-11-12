class HelperCalls
  @tag_name = "helper-calls"
  @total
  @status
  @initial
  @count

  def initialize
    @total = 1234
    @count = 0
    @status = "idle"
    @initial = rebuild
  end

  def rebuild
    wrap(number(@total), " init")
  end

  def number(value)
    value.to_s
  end

  def wrap(value, suffix)
    value + suffix
  end

  def total_label
    compact(@total)
  end

  def compact(value)
    value.to_s + " total"
  end

  def html
    %Q{
      <span class="direct">{number(@total)}</span>
      <span class="later">{total_label}</span>
      <span class="later-direct">{compact(@total)}</span>
      <span class="nested">{wrap(number(@total), " nested")}</span>
      <span class="initial">{@initial}</span>
      <span class="status">{@status}</span>
      <span class="count">{@count}</span>
    }
  end

  def bump
    @total += 1
  end

  def apply(value)
    @count += value
    @status = "count=#{@count} label=#{total_label} direct=#{number(@total)}"
  end
end
