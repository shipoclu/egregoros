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
    imports = module_imports(ImageProxy)

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

  test "normalizes JPEG, WebP, and AVIF inputs to the fixed WebP output", %{
    safe_webp: safe_webp
  } do
    inputs = [
      {image_binary(3, 2, ".jpg"), " image/JPEG ; charset=binary"},
      {image_binary(3, 2, ".webp"), "IMAGE/WEBP"},
      {image_binary(3, 2, ".avif"), "image/avif"}
    ]

    for {input, declared_content_type} <- inputs do
      assert {:ok, %{body: ^safe_webp, content_type: "image/webp"}} =
               ImageProxy.sanitize(input, declared_content_type)
    end
  end

  test "accepts bounded VP8X and VP8L still-image containers", %{safe_webp: safe_webp} do
    vp8x =
      webp([
        webp_chunk("VP8X", <<0, 0, 0, 0, 2::little-24, 1::little-24>>),
        webp_chunk("EXIF", "safe metadata"),
        webp_chunk("VP8 ", <<0, 0, 0, 0x9D, 0x01, 0x2A, 3::little-16, 2::little-16>>)
      ])

    packed = Bitwise.bor(2, Bitwise.bsl(1, 14))
    vp8l = webp([webp_chunk("VP8L", <<0x2F, packed::little-32>>)])

    for input <- [vp8x, vp8l] do
      assert {:ok, %{body: ^safe_webp, content_type: "image/webp"}} =
               ImageProxy.sanitize(input, "image/webp")
    end
  end

  test "requires the declared MIME type to match the actual raster signature" do
    png = image_binary(2, 2, ".png")

    assert {:error, :image_content_type_mismatch} =
             ImageProxy.sanitize(png, "image/jpeg")
  end

  test "rejects invalid argument types, invalid UTF-8, and empty media types" do
    png = image_binary(2, 2, ".png")

    for {body, declared_content_type, expected_error} <- [
          {nil, "image/png", :invalid_image},
          {%{}, "image/png", :invalid_image},
          {png, nil, :invalid_image},
          {png, %{}, :invalid_image},
          {png, <<"image/png", 0xFF>>, :image_content_type_mismatch},
          {png, "  ; smuggled=image/png", :image_content_type_mismatch}
        ] do
      assert {:error, ^expected_error} =
               ImageProxy.sanitize(body, declared_content_type)
    end
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

  test "fails closed on an invalid pre-READY worker handshake", %{
    launcher: launcher,
    python: python
  } do
    replace_executable(
      launcher,
      """
      #!#{python}
      import sys
      sys.stdout.write("NOT-READY\\n")
      sys.stdout.flush()
      """
    )

    assert {:error, :image_processing_unavailable} =
             ImageProxy.sanitize(image_binary(2, 2, ".png"), "image/png")
  end

  test "bounds diagnostics before accepting the worker READY handshake", %{
    launcher: launcher,
    python: python
  } do
    replace_executable(
      launcher,
      """
      #!#{python}
      import sys, time
      sys.stdout.write("x" * 5000)
      sys.stdout.flush()
      time.sleep(30)
      """
    )

    assert {:error, :image_processing_unavailable} =
             ImageProxy.sanitize(image_binary(2, 2, ".png"), "image/png")
  end

  test "fails closed when the worker never reaches its READY handshake", %{
    launcher: launcher,
    python: python
  } do
    replace_executable(
      launcher,
      """
      #!#{python}
      import time
      time.sleep(30)
      """
    )

    Application.put_env(:egregoros, :mini_app_image_processing_timeout_ms, 200)

    assert {:error, :image_processing_unavailable} =
             ImageProxy.sanitize(image_binary(2, 2, ".png"), "image/png")
  end

  test "fails closed when a worker exits during a partial READY handshake", %{
    launcher: launcher,
    python: python
  } do
    replace_executable(
      launcher,
      """
      #!#{python}
      import sys
      sys.stdout.write("REA")
      sys.stdout.flush()
      """
    )

    assert {:error, :image_processing_unavailable} =
             ImageProxy.sanitize(image_binary(2, 2, ".png"), "image/png")
  end

  test "rejects unsafe worker paths and temporary-directory configuration", %{
    decoder: decoder,
    launcher: launcher,
    root: root
  } do
    Application.put_env(:egregoros, :mini_app_image_decoder, launcher)

    assert {:error, :image_processing_unavailable} =
             ImageProxy.sanitize(image_binary(2, 2, ".png"), "image/png")

    Application.put_env(:egregoros, :mini_app_image_decoder, decoder)
    Application.put_env(:egregoros, :mini_app_image_worker_script, Path.join(root, "missing.py"))

    assert {:error, :image_processing_unavailable} =
             ImageProxy.sanitize(image_binary(2, 2, ".png"), "image/png")

    Application.put_env(:egregoros, :mini_app_image_worker_script, launcher)
    Application.put_env(:egregoros, :mini_app_image_tmp_dir, "relative/tmp")

    assert {:error, :image_processing_unavailable} =
             ImageProxy.sanitize(image_binary(2, 2, ".png"), "image/png")

    Application.put_env(:egregoros, :mini_app_image_tmp_dir, Path.join(root, "missing"))

    assert {:error, :image_processing_unavailable} =
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

  test "rejects malformed PNG chunk order, terminators, and animation data" do
    png = image_binary(2, 2, ".png")
    <<signature::binary-size(8), ihdr::binary-size(25), chunks::binary>> = png
    {idat_type_offset, 4} = :binary.match(chunks, "IDAT")
    idat_chunk_offset = idat_type_offset - 4

    <<_preceding_chunks::binary-size(idat_chunk_offset), idat_length::big-32, "IDAT",
      idat_rest::binary>> = chunks

    <<idat_data::binary-size(idat_length), idat_crc::big-32, iend::binary>> = idat_rest
    idat = <<idat_length::big-32, "IDAT", idat_data::binary, idat_crc::big-32>>

    malformed = [
      signature <> png_chunk("aa1a", <<>>) <> ihdr <> chunks,
      signature <> idat <> ihdr <> iend,
      signature <> ihdr <> iend,
      signature <> ihdr <> idat <> png_chunk("IEND", <<0>>),
      signature <> ihdr <> idat <> iend <> png_chunk("aaAa", <<>>),
      signature <> ihdr <> ihdr <> chunks
    ]

    for input <- malformed do
      assert {:error, :invalid_image} = ImageProxy.sanitize(input, "image/png")
    end

    assert {:error, :animated_image_not_allowed} =
             ImageProxy.sanitize(
               insert_png_chunk_after_header(png, "fdAT", <<0::32>>),
               "image/png"
             )
  end

  test "rejects truncated PNG chunk streams and zero dimensions" do
    png = image_binary(2, 2, ".png")
    <<signature::binary-size(8), ihdr::binary-size(25), remaining_chunks::binary>> = png

    assert {:error, :invalid_image} =
             ImageProxy.sanitize(signature <> ihdr, "image/png")

    assert {:error, :invalid_image} =
             ImageProxy.sanitize(
               signature <> ihdr <> <<5::big-32, "IDAT", "x">>,
               "image/png"
             )

    zero_width_ihdr = png_chunk("IHDR", <<0::big-32, 2::big-32, 8, 2, 0, 0, 0>>)

    assert {:error, :invalid_image} =
             ImageProxy.sanitize(
               signature <> zero_width_ihdr <> remaining_chunks,
               "image/png"
             )
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

  test "rejects malformed, ambiguous, and animated WebP containers" do
    vp8 = webp_chunk("VP8 ", <<0, 0, 0, 0x9D, 0x01, 0x2A, 2::little-16, 2::little-16>>)
    vp8l = webp_chunk("VP8L", <<0x2F, 0::little-32>>)

    malformed = [
      webp([]),
      webp([webp_chunk("EXIF", <<>>)]),
      webp([webp_chunk("VP8X", <<0, 0, 0>>), vp8]),
      webp([vp8, vp8l]),
      webp([webp_chunk("JUNK", <<>>), vp8]),
      webp([webp_chunk("VP8 ", <<0, 0, 0>>)]),
      binary_part(webp([vp8]), 0, byte_size(webp([vp8])) - 1)
    ]

    for input <- malformed do
      assert {:error, error} = ImageProxy.sanitize(input, "image/webp")
      assert error in [:invalid_image, :unsupported_image_type]
    end

    assert {:error, :animated_image_not_allowed} =
             ImageProxy.sanitize(
               webp([
                 webp_chunk("VP8X", <<0x02, 0, 0, 0, 1::little-24, 1::little-24>>),
                 vp8
               ]),
               "image/webp"
             )

    assert {:error, :animated_image_not_allowed} =
             ImageProxy.sanitize(webp([webp_chunk("ANMF", <<>>), vp8]), "image/webp")
  end

  test "accepts a still AVIF brand and rejects animated or malformed AVIF headers", %{
    safe_webp: safe_webp
  } do
    assert {:ok, %{body: ^safe_webp, content_type: "image/webp"}} =
             ImageProxy.sanitize(avif("avif", ["mif1"]), "image/avif")

    for input <- [avif("avis", ["mif1"]), avif("avif", ["avis"])] do
      assert {:error, :animated_image_not_allowed} =
               ImageProxy.sanitize(input, "image/avif")
    end

    for input <- [
          <<12::big-32, "ftyp", "avif">>,
          <<24::big-32, "ftyp", "avif", 0::32>>,
          avif("mif1", ["miaf"])
        ] do
      assert {:error, error} = ImageProxy.sanitize(input, "image/avif")
      assert error in [:invalid_image, :unsupported_image_type]
    end
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

  defp module_imports(module) do
    with path when is_list(path) <- :code.which(module),
         {:ok, {^module, [imports: imports]}} <- :beam_lib.chunks(path, [:imports]) do
      imports
    else
      _coverage_instrumented -> compile_uninstrumented_imports(module)
    end
  end

  defp compile_uninstrumented_imports(module) do
    directory =
      Path.join(System.tmp_dir!(), "egregoros-image-proxy-beam-#{Ecto.UUID.generate()}")

    source = Path.expand("../../../lib/egregoros/mini_apps/image_proxy.ex", __DIR__)
    elixirc = System.find_executable("elixirc") || flunk("elixirc is required for this test")
    :ok = File.mkdir(directory)

    code_path_arguments =
      Enum.flat_map(:code.get_path(), fn path -> ["-pa", List.to_string(path)] end)

    try do
      arguments =
        code_path_arguments ++
          ["--ignore-module-conflict", "-o", directory, source]

      assert {diagnostics, 0} =
               System.cmd(elixirc, arguments, stderr_to_stdout: true)

      assert diagnostics == ""

      beam_path = Path.join(directory, Atom.to_string(module) <> ".beam")

      assert {:ok, {^module, [imports: imports]}} =
               :beam_lib.chunks(String.to_charlist(beam_path), [:imports])

      imports
    after
      File.rm_rf!(directory)
    end
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

  defp webp(chunks) do
    chunks = IO.iodata_to_binary(chunks)

    <<byte_size(chunks) + 4::little-32, "WEBP", chunks::binary>>
    |> then(&<<"RIFF", &1::binary>>)
  end

  defp webp_chunk(type, data) do
    padding = if rem(byte_size(data), 2) == 0, do: <<>>, else: <<0>>
    <<type::binary-size(4), byte_size(data)::little-32, data::binary, padding::binary>>
  end

  defp avif(major_brand, compatible_brands) do
    brands = IO.iodata_to_binary(compatible_brands)
    size = 16 + byte_size(brands)
    <<size::big-32, "ftyp", major_brand::binary-size(4), 0::big-32, brands::binary>>
  end
end
