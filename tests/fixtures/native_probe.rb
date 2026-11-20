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
