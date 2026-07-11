defmodule Egregoros.MiniApps.ImageProxyTest do
  use ExUnit.Case, async: false

  alias Egregoros.MiniApps.ImageProxy

  @config_keys [
    :mini_app_image_decoder,
    :mini_app_image_kill,
    :mini_app_image_processing_timeout_ms,
    :mini_app_image_python,
    :mini_app_image_tmp_dir,
    :mini_app_image_worker_script
  ]

  setup do
    previous = Map.new(@config_keys, &{&1, Application.fetch_env(:egregoros, &1)})
    root = Path.join(System.tmp_dir!(), "egregoros-image-proxy-test-#{Ecto.UUID.generate()}")
    :ok = File.mkdir(root)
    :ok = File.chmod(root, 0o700)

    python = System.find_executable("python3") || raise "Python 3 is required for this test"
    launcher = Path.join(root, "launcher.py")
    decoder = Path.join(root, "magick")
    safe_webp = image_binary(3, 2, ".webp")

    write_executable(
      launcher,
      """
      #!#{python}
      import os, signal, sys
      if len(sys.argv) != 7:
          raise SystemExit(70)
      if os.getpgrp() != os.getpid():
          os.setsid()
      signal.alarm(10)
      print("READY", flush=True)
      os.execv(sys.argv[1], [sys.argv[1]] + sys.argv[2:])
      """
    )

    write_executable(
      decoder,
      """
      #!#{python}
      import base64, sys
      with open(sys.argv[-1], "xb") as output:
          output.write(base64.b64decode(#{inspect(Base.encode64(safe_webp))}))
      """
    )

    Application.put_env(:egregoros, :mini_app_image_python, python)
    Application.put_env(:egregoros, :mini_app_image_decoder, decoder)
    Application.put_env(:egregoros, :mini_app_image_tmp_dir, root)
    Application.put_env(:egregoros, :mini_app_image_worker_script, launcher)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:egregoros, key, value)
        {key, :error} -> Application.delete_env(:egregoros, key)
      end)

      File.rm_rf!(root)
    end)

    %{decoder: decoder, launcher: launcher, python: python, root: root, safe_webp: safe_webp}
  end

  test "the application module never links the in-process Image or Vix decoders" do
    assert {:ok, {_module, [imports: imports]}} =
             ImageProxy
             |> :code.which()
             |> :beam_lib.chunks([:imports])

    refute Enum.any?(imports, fn {module, _function, _arity} ->
             module == Image or module |> Atom.to_string() |> String.starts_with?("Elixir.Vix.")
           end)
  end

  test "the supplied runtime image installs every image-worker executable" do
    dockerfile =
      __DIR__
      |> Path.join("../../..")
      |> Path.join("Dockerfile")
      |> File.read!()

    assert dockerfile =~ "    imagemagick \\\n"
    assert dockerfile =~ "    procps \\\n"
    assert dockerfile =~ "    python3-minimal \\\n"
  end

  test "fully decodes a raster, strips it, and emits one fixed safe format" do
    png = image_binary(3, 2, ".png")

    assert {:ok, %{body: body, content_type: "image/webp"}} =
             ImageProxy.sanitize(png, "image/png")

    assert body != png
    assert <<"RIFF", _size::little-32, "WEBP", _rest::binary>> = body
    assert {:ok, image} = Image.open(body, fail_on: :error)
    assert Image.shape(image) == {3, 2, 3}
    assert Image.pages(image) == 1
  end

  test "requires the declared MIME type to match the actual raster signature" do
    png = image_binary(2, 2, ".png")

    assert {:error, :image_content_type_mismatch} =
             ImageProxy.sanitize(png, "image/jpeg")
  end

  test "rejects truncated files and non-raster active content" do
    assert {:error, :invalid_image} =
             ImageProxy.sanitize(<<137, 80, 78, 71, 13, 10, 26, 10>>, "image/png")

    assert {:error, :unsupported_image_type} =
             ImageProxy.sanitize("<svg xmlns='http://www.w3.org/2000/svg'></svg>", "image/png")
  end

  test "rejects dimensions and decoded pixel counts outside the proxy budget" do
    too_wide = image_binary(10_001, 1, ".png")
    too_many_pixels = image_binary(4_000, 2_501, ".png")

    assert {:error, :image_dimensions_too_large} =
             ImageProxy.sanitize(too_wide, "image/png")

    assert {:error, :image_pixel_count_too_large} =
             ImageProxy.sanitize(too_many_pixels, "image/png")
  end

  test "rejects compressed input larger than the network asset ceiling" do
    assert {:error, :image_too_large} =
             ImageProxy.sanitize(:binary.copy(<<0>>, 5_000_001), "image/png")
  end

  test "fails closed when any required worker executable is unavailable" do
    Application.put_env(:egregoros, :mini_app_image_decoder, "/missing/magick")

    assert {:error, :image_processing_unavailable} =
             ImageProxy.sanitize(image_binary(2, 2, ".png"), "image/png")
  end

  test "kills a timed-out worker group, removes its files, and recovers the pool", %{
    decoder: decoder,
    python: python,
    root: root,
    safe_webp: safe_webp
  } do
    pid_path = Path.join(root, "timed-out-worker.pid")

    replace_executable(
      decoder,
      """
      #!#{python}
      import os, time
      with open(#{inspect(pid_path)}, "x") as marker:
          marker.write(str(os.getpid()))
      time.sleep(30)
      """
    )

    Application.put_env(:egregoros, :mini_app_image_processing_timeout_ms, 500)

    assert {:error, :image_processing_timeout} =
             ImageProxy.sanitize(image_binary(2, 2, ".png"), "image/png")

    assert {os_pid, ""} = pid_path |> File.read!() |> Integer.parse()
    kill = System.find_executable("kill") || raise "kill is required for this test"

    assert {_output, status} =
             System.cmd(kill, ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)

    assert status != 0
    assert image_work_directories(root) == []

    write_safe_decoder(decoder, python, safe_webp)
    Application.delete_env(:egregoros, :mini_app_image_processing_timeout_ms)

    assert {:ok, %{content_type: "image/webp"}} =
             ImageProxy.sanitize(image_binary(2, 2, ".png"), "image/png")
  end

  test "contains a crashing native worker and makes its slot reusable", %{
    decoder: decoder,
    python: python,
    safe_webp: safe_webp
  } do
    replace_executable(
      decoder,
      """
      #!#{python}
      import os
      os.abort()
      """
    )

    assert {:error, :invalid_image} =
             ImageProxy.sanitize(image_binary(2, 2, ".png"), "image/png")

    write_safe_decoder(decoder, python, safe_webp)

    assert {:ok, %{content_type: "image/webp"}} =
             ImageProxy.sanitize(image_binary(2, 2, ".png"), "image/png")
  end

  test "reports a failed timeout kill instead of silently claiming cleanup", %{
    decoder: decoder,
    python: python,
    root: root
  } do
    pid_path = Path.join(root, "unclean-worker.pid")
    kill_log = Path.join(root, "kill-arguments")
    fake_kill = Path.join(root, "kill")

    replace_executable(
      decoder,
      """
      #!#{python}
      import os, time
      with open(#{inspect(pid_path)}, "x") as marker:
          marker.write(str(os.getpid()))
      time.sleep(30)
      """
    )

    write_executable(
      fake_kill,
      """
      #!#{python}
      import sys
      with open(#{inspect(kill_log)}, "w") as report:
          report.write(" ".join(sys.argv[1:]))
      raise SystemExit(1)
      """
    )

    Application.put_env(:egregoros, :mini_app_image_kill, fake_kill)
    Application.put_env(:egregoros, :mini_app_image_processing_timeout_ms, 200)

    assert {:error, :image_worker_cleanup_failed} =
             ImageProxy.sanitize(image_binary(2, 2, ".png"), "image/png")

    assert {os_pid, ""} = pid_path |> File.read!() |> Integer.parse()
    assert File.read!(kill_log) =~ "-#{os_pid}"

    real_kill = System.find_executable("kill") || raise "kill is required for this test"
    _ = System.cmd(real_kill, ["-KILL", "--", "-#{os_pid}"], stderr_to_stdout: true)
  end

  test "rejects worker diagnostics and output beyond their fixed ceilings", %{
    decoder: decoder,
    python: python
  } do
    replace_executable(
      decoder,
      """
      #!#{python}
      import sys
      sys.stdout.write("x" * 5000)
      sys.stdout.flush()
      """
    )

    assert {:error, :invalid_image} =
             ImageProxy.sanitize(image_binary(2, 2, ".png"), "image/png")

    replace_executable(
      decoder,
      """
      #!#{python}
      import sys
      with open(sys.argv[-1], "xb") as output:
          output.write(b"x" * 5000001)
      """
    )

    assert {:error, :sanitized_image_too_large} =
             ImageProxy.sanitize(image_binary(2, 2, ".png"), "image/png")
  end

  test "rejects animation markers and malformed PNG structure before decoding" do
    png = image_binary(2, 2, ".png")
    animated_png = insert_png_chunk_after_header(png, "acTL", <<0, 0, 0, 2, 0, 0, 0, 0>>)

    assert {:error, :animated_image_not_allowed} =
             ImageProxy.sanitize(animated_png, "image/png")

    assert {:error, :invalid_image} =
             ImageProxy.sanitize(png <> "polyglot", "image/png")

    <<prefix::binary-size(29), byte, tail::binary>> = png

    assert {:error, :invalid_image} =
             ImageProxy.sanitize(prefix <> <<Bitwise.bxor(byte, 1)>> <> tail, "image/png")
  end

  test "bounds container metadata work before starting an OS worker" do
    png = image_binary(2, 2, ".png")
    chunk = png_chunk("aaAa", <<>>)
    complex_png = insert_png_chunks_after_header(png, :binary.copy(chunk, 1_025))

    assert {:error, :image_container_too_complex} =
             ImageProxy.sanitize(complex_png, "image/png")

    <<"RIFF", old_size::little-32, "WEBP", chunks::binary>> = image_binary(2, 2, ".webp")
    metadata = :binary.copy(<<"EXIF", 0::little-32>>, 1_025)

    complex_webp =
      <<"RIFF", old_size + byte_size(metadata)::little-32, "WEBP", metadata::binary,
        chunks::binary>>

    assert {:error, :image_container_too_complex} =
             ImageProxy.sanitize(complex_webp, "image/webp")
  end

  test "rejects animation markers in WebP input" do
    webp = image_binary(2, 2, ".webp")
    <<"RIFF", old_size::little-32, "WEBP", chunks::binary>> = webp
    animation_chunk = <<"ANIM", 6::little-32, 0::little-48>>

    animated =
      <<"RIFF", old_size + byte_size(animation_chunk)::little-32, "WEBP", animation_chunk::binary,
        chunks::binary>>

    assert {:error, :animated_image_not_allowed} =
             ImageProxy.sanitize(animated, "image/webp")
  end

  test "rejects control characters and oversized declared media types" do
    png = image_binary(2, 2, ".png")

    assert {:error, :image_content_type_mismatch} =
             ImageProxy.sanitize(png, "image/png\r\nx-smuggled: yes")

    assert {:error, :image_content_type_mismatch} =
             ImageProxy.sanitize(png, :binary.copy("a", 129))
  end

  test "the production launcher denies child creation on Linux", %{
    decoder: decoder,
    python: python,
    root: root,
    safe_webp: safe_webp
  } do
    if :os.type() == {:unix, :linux} do
      marker = Path.join(root, "fork-result")

      replace_executable(
        decoder,
        """
        #!#{python}
        import base64, os, sys
        try:
            os.fork()
            result = "allowed"
        except OSError:
            result = "blocked"
        with open(#{inspect(marker)}, "x") as report:
            report.write(result)
        output_path = sys.argv[-1].removeprefix("WEBP:")
        with open(output_path, "xb") as output:
            output.write(base64.b64decode(#{inspect(Base.encode64(safe_webp))}))
        """
      )

      Application.delete_env(:egregoros, :mini_app_image_worker_script)

      assert {:ok, %{content_type: "image/webp"}} =
               ImageProxy.sanitize(image_binary(2, 2, ".png"), "image/png")

      assert File.read!(marker) == "blocked"
    end
  end

  test "the production policy is deny-by-default and carries every resource ceiling" do
    private_dir = :egregoros |> :code.priv_dir() |> List.to_string()
    launcher = File.read!(Path.join(private_dir, "mini_app_image_worker.py"))
    policy = File.read!(Path.join([private_dir, "mini_app_image_policy", "policy.xml"]))

    for required <- ~w(RLIMIT_AS RLIMIT_CORE RLIMIT_CPU RLIMIT_FSIZE RLIMIT_NOFILE RLIMIT_NPROC) do
      assert launcher =~ required
    end

    for required <- [
          ~s(domain="delegate" rights="none" pattern="*"),
          ~s(domain="filter" rights="none" pattern="*"),
          ~s(domain="module" rights="none" pattern="*"),
          ~s(name="list-length" value="2"),
          ~s(name="width" value="10KP"),
          ~s(name="height" value="10KP")
        ] do
      assert policy =~ required
    end
  end

  test "an installed production decoder honors the bundled allowlist policy", %{root: root} do
    if decoder = System.find_executable("magick") || System.find_executable("convert") do
      private_dir = :egregoros |> :code.priv_dir() |> List.to_string()
      policy_dir = Path.join(private_dir, "mini_app_image_policy")
      input_path = Path.join(root, "policy-input.png")
      output_path = Path.join(root, "policy-output.webp")
      svg_path = Path.join(root, "denied.svg")

      :ok = File.write(input_path, image_binary(2, 2, ".png"), [:exclusive])
      :ok = File.write(svg_path, ~s(<svg xmlns="http://www.w3.org/2000/svg"/>), [:exclusive])

      environment = [
        {"MAGICK_CONFIGURE_PATH", policy_dir},
        {"MAGICK_DISK_LIMIT", "0"},
        {"MAGICK_THREAD_LIMIT", "1"}
      ]

      assert {_diagnostics, 0} =
               System.cmd(
                 decoder,
                 ["PNG:#{input_path}[0]", "-strip", "WEBP:#{output_path}"],
                 env: environment,
                 stderr_to_stdout: true
               )

      assert <<"RIFF", _::little-32, "WEBP", _::binary>> = File.read!(output_path)

      assert {_diagnostics, status} =
               System.cmd(
                 decoder,
                 ["SVG:#{svg_path}", "WEBP:#{Path.join(root, "denied.webp")}"],
                 env: environment,
                 stderr_to_stdout: true
               )

      assert status != 0
    end
  end

  defp image_binary(width, height, suffix) do
    {:ok, image} = Image.new(width, height, color: :blue)
    {:ok, body} = Image.write(image, :memory, suffix: suffix, strip_metadata: true)
    body
  end

  defp write_executable(path, contents) do
    :ok = File.write(path, contents, [:exclusive])
    :ok = File.chmod(path, 0o700)
  end

  defp replace_executable(path, contents) do
    :ok = File.write(path, contents)
    :ok = File.chmod(path, 0o700)
  end

  defp write_safe_decoder(path, python, webp) do
    replace_executable(
      path,
      """
      #!#{python}
      import base64, sys
      with open(sys.argv[-1], "xb") as output:
          output.write(base64.b64decode(#{inspect(Base.encode64(webp))}))
      """
    )
  end

  defp image_work_directories(root) do
    root
    |> File.ls!()
    |> Enum.filter(&String.starts_with?(&1, "egregoros-miniapp-image-"))
  end

  defp insert_png_chunk_after_header(
         <<signature::binary-size(8), ihdr::binary-size(25), chunks::binary>>,
         type,
         data
       ) do
    length = byte_size(data)
    crc = :erlang.crc32([type, data])

    <<signature::binary, ihdr::binary, length::big-32, type::binary-size(4), data::binary,
      crc::big-32, chunks::binary>>
  end

  defp insert_png_chunks_after_header(
         <<signature::binary-size(8), ihdr::binary-size(25), chunks::binary>>,
         inserted
       ) do
    <<signature::binary, ihdr::binary, inserted::binary, chunks::binary>>
  end

  defp png_chunk(type, data) do
    <<byte_size(data)::big-32, type::binary-size(4), data::binary,
      :erlang.crc32([type, data])::big-32>>
  end
end
