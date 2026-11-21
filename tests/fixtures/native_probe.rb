class NativeProbe
  def initialize
    @label = "ready"
  end

  def label
    @label
  end

  def change(label)
    @label = label
  end

  def unsupported
    Mochi.after(0, :label)
  end
end

class BrokenNativeProbe
  def initialize
    @value = 1
    @value / 0
  end
end

class HostEffectNativeProbe
  def initialize
    Mochi.after(0, :initialize)
  end
end

class TypedNativeProbe
  def __mochi_apply_props(values, initial)
    @station = values["station"] if values.key?("station")
    @meta = values["meta"] if values.key?("meta")
  end

  def initialize
    @initial = @station
    @station = 0
    @meta["row"][0] = "constructor"
  end

  def label
    "#{@initial}:#{@station}:#{@meta["row"][0]}"
  end

  def publish
    Mochi.emit_child("confirm", id: @station)
  end

  def publish_then_fail
    publish
    @station / 0
  end

  def publish_with_host_effect
    publish
    Mochi.after(0, :label)
  end
end
