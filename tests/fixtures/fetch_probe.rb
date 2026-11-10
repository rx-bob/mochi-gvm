class FetchProbe
  @tag_name = "fetch-probe"
  @status
  @ok
  @row
  @error

  def initialize
    @status = 0
    @ok = false
    @row = "none"
    @error = "none"
  end

  def html
    %Q{
      <p class="status">{@status}</p>
      <p class="ok">{@ok}</p>
      <p class="row">{@row}</p>
      <p class="error">{@error}</p>
      <button class="load" onclick="{load}">Load</button>
      <button class="fail" onclick="{fail}">Fail</button>
      <button class="offline" onclick="{offline}">Offline</button>
    }
  end

  def load
    Mochi.fetch("/api/logs", :on_logs)
  end

  def fail
    Mochi.fetch("/api/fail", :on_logs)
  end

  def offline
    Mochi.fetch("/api/offline", :on_logs)
  end

  def on_logs(res)
    @status = res[:status]
    @ok = res[:ok]
    if res[:error]
      @error = res[:error]
    else
      @error = "none"
    end
    if res[:data]
      @row = res[:data][:rows][0]
    else
      @row = "none"
    end
  end
end
