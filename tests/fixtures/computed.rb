# This fixture uses the compiler's lowered declaration so VM guards can also
# exercise programs the source validator would reject.
module ComputedEffects
  def self.write(value)
    value[0] = 99
  end

  def self.host
    Mochi.emit("forbidden", 1)
  end
end

class ComputedProbe
  __mochi_computed(:rows, [:@count])
  __mochi_computed(:summary, [:@count])
  __mochi_computed(:recursive, [])
  __mochi_computed(:write, [:@count])
  __mochi_computed(:mutate, [:@items])
  __mochi_computed(:host, [])
  __mochi_computed(:native, [])
  __mochi_computed(:text, [])
  __mochi_computed(:local_work, [:@count])

  def initialize
    @count = 2
    @other = 0
    @items = [1]
  end

  def rows
    [{"value" => 12 / @count}, [@count]]
  end

  def text
    "computed text"
  end

  def local_work
    values = []
    100.times { |i| values << {"value" => i} }
    [rows, values[99]]
  end

  def summary
    rows[0]["value"].to_s
  end

  def first_binding
    summary
  end

  def second_binding
    rows[0]["value"].to_s
  end

  def change(value)
    @count = value
  end

  def unrelated
    @other += 1
  end

  def recursive
    recursive
  end

  def write
    @count = 99
  end

  def mutate
    ComputedEffects.write(@items)
  end

  def host
    ComputedEffects.host
  end

  def native
    external
  end
end

class ComputedChild < ComputedProbe
end

class ComputedOverride < ComputedProbe
  def rows
    @other += 1
    @other
  end
end
