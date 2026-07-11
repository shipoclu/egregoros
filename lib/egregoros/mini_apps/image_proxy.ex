defmodule Egregoros.MiniApps.ImageProxy do
  @moduledoc """
  Sanitizes untrusted mini-app previews outside the Egregoros VM.

  The application process performs only bounded container parsing. Pixel
  decoding and WebP encoding happen in a disposable, resource-limited OS
  process. A decoder crash, native-library abort, or allocation failure is
  therefore contained outside the node that holds sessions and secrets.
  """

  import Bitwise

  @behaviour Egregoros.MiniApps.ImageSanitizer

  @max_input_bytes 5_000_000
  @max_output_bytes 5_000_000
  @max_dimension 10_000
  @max_pixels 10_000_000
  @max_container_chunks 1_024
  @processing_timeout_ms 5_000
  @task_grace_ms 1_000
  @startup_timeout_ms 1_000
  @cleanup_timeout_ms 500
  @port_line_bytes 1_024
  @max_worker_diagnostics_bytes 4_096
  @output_content_type "image/webp"
  @png_signature <<137, 80, 78, 71, 13, 10, 26, 10>>

  @type sanitized :: %{body: binary(), content_type: binary()}

  @impl true
  @spec sanitize(binary(), binary()) :: {:ok, sanitized()} | {:error, atom()}
  def sanitize(body, declared_content_type)
      when is_binary(body) and is_binary(declared_content_type) do
    with :ok <- validate_input_size(body),
         {:ok, detected_content_type} <- detect_content_type(body),
         :ok <- content_type_matches(declared_content_type, detected_content_type),
         :ok <- validate_container(body, detected_content_type) do
      run_image_task(fn -> sanitize_in_worker(body, detected_content_type) end)
    end
  rescue
    _error -> {:error, :invalid_image}
  catch
    _, _ -> {:error, :invalid_image}
  end

  def sanitize(_body, _declared_content_type), do: {:error, :invalid_image}

  defp validate_input_size(body) when byte_size(body) <= @max_input_bytes, do: :ok
  defp validate_input_size(_body), do: {:error, :image_too_large}

  defp detect_content_type(<<@png_signature, 0, 0, 0, 13, "IHDR", _rest::binary>>),
    do: {:ok, "image/png"}

  defp detect_content_type(<<@png_signature, _rest::binary>>), do: {:error, :invalid_image}

  defp detect_content_type(<<0xFF, 0xD8, 0xFF, _rest::binary>>), do: {:ok, "image/jpeg"}

  defp detect_content_type(<<"RIFF", size::little-32, "WEBP", _rest::binary>> = body)
       when size + 8 == byte_size(body),
       do: {:ok, "image/webp"}

  defp detect_content_type(<<box_size::big-32, "ftyp", rest::binary>> = body)
       when box_size >= 16 and box_size <= 256 and box_size <= byte_size(body) do
    brand_bytes = box_size - 8

    case rest do
      <<major_brand::binary-size(4), _minor_version::binary-size(4),
        compatible::binary-size(brand_bytes - 8), _tail::binary>> ->
        brands = [major_brand | for(<<brand::binary-size(4) <- compatible>>, do: brand)]

        if Enum.any?(brands, &(&1 in ["avif", "avis"])),
          do: {:ok, "image/avif"},
          else: {:error, :unsupported_image_type}

      _ ->
        {:error, :invalid_image}
    end
  end

  defp detect_content_type(_body), do: {:error, :unsupported_image_type}

  defp content_type_matches(declared, detected)
       when byte_size(declared) <= 128 and byte_size(detected) <= 128 do
    if String.valid?(declared) and not contains_control?(declared) do
      normalized =
        declared
        |> String.split(";", parts: 2)
        |> List.first()
        |> String.trim()
        |> String.downcase()

      if normalized == detected,
        do: :ok,
        else: {:error, :image_content_type_mismatch}
    else
      {:error, :image_content_type_mismatch}
    end
  end

  defp content_type_matches(_declared, _detected),
    do: {:error, :image_content_type_mismatch}

  defp contains_control?(value) do
    Enum.any?(:binary.bin_to_list(value), &(&1 < 0x20 or &1 == 0x7F))
  end

  defp validate_container(body, "image/png"), do: validate_png(body)
  defp validate_container(body, "image/webp"), do: validate_webp(body)
  defp validate_container(body, "image/avif"), do: validate_avif(body)
  defp validate_container(_body, "image/jpeg"), do: :ok

  defp validate_png(<<@png_signature, chunks::binary>>) do
    with {:ok, dimensions} <- parse_png_chunks(chunks, nil, false, 0),
         :ok <- validate_dimensions(dimensions) do
      :ok
    end
  end

  defp validate_png(_body), do: {:error, :invalid_image}

  defp parse_png_chunks(_chunks, _dimensions, _seen_image_data, count)
       when count >= @max_container_chunks,
       do: {:error, :image_container_too_complex}

  defp parse_png_chunks(<<>>, _dimensions, _seen_image_data, _count),
    do: {:error, :invalid_image}

  defp parse_png_chunks(
         <<length::big-32, type::binary-size(4), rest::binary>>,
         dimensions,
         seen,
         count
       )
       when length <= @max_input_bytes and byte_size(rest) >= length + 4 do
    <<data::binary-size(length), expected_crc::big-32, tail::binary>> = rest

    with :ok <- valid_png_chunk_type(type),
         :ok <- valid_png_crc(type, data, expected_crc) do
      parse_png_chunk(type, data, tail, dimensions, seen, count + 1)
    end
  end

  defp parse_png_chunks(_chunks, _dimensions, _seen, _count), do: {:error, :invalid_image}

  defp parse_png_chunk(
         "IHDR",
         <<width::big-32, height::big-32, _::binary-size(5)>>,
         tail,
         nil,
         false,
         count
       ) do
    parse_png_chunks(tail, {width, height}, false, count)
  end

  defp parse_png_chunk("IHDR", _data, _tail, _dimensions, _seen, _count),
    do: {:error, :invalid_image}

  defp parse_png_chunk("acTL", _data, _tail, _dimensions, _seen, _count),
    do: {:error, :animated_image_not_allowed}

  defp parse_png_chunk("fdAT", _data, _tail, _dimensions, _seen, _count),
    do: {:error, :animated_image_not_allowed}

  defp parse_png_chunk("IDAT", _data, tail, dimensions, _seen, count) when dimensions != nil do
    parse_png_chunks(tail, dimensions, true, count)
  end

  defp parse_png_chunk("IEND", <<>>, <<>>, dimensions, true, _count) when dimensions != nil,
    do: {:ok, dimensions}

  defp parse_png_chunk("IEND", _data, _tail, _dimensions, _seen, _count),
    do: {:error, :invalid_image}

  defp parse_png_chunk(_type, _data, tail, dimensions, seen, count) when dimensions != nil do
    parse_png_chunks(tail, dimensions, seen, count)
  end

  defp parse_png_chunk(_type, _data, _tail, _dimensions, _seen, _count),
    do: {:error, :invalid_image}

  defp valid_png_chunk_type(type) do
    if Enum.all?(:binary.bin_to_list(type), &(&1 in ?A..?Z or &1 in ?a..?z)),
      do: :ok,
      else: {:error, :invalid_image}
  end

  defp valid_png_crc(type, data, expected) do
    if :erlang.crc32([type, data]) == expected,
      do: :ok,
      else: {:error, :invalid_image}
  end

  defp validate_webp(<<"RIFF", _size::little-32, "WEBP", chunks::binary>>) do
    with {:ok, dimensions} <- parse_webp_chunks(chunks, nil, 0, 0),
         :ok <- validate_dimensions(dimensions) do
      :ok
    end
  end

  defp validate_webp(_body), do: {:error, :invalid_image}

  defp parse_webp_chunks(_chunks, _dimensions, _images, count)
       when count >= @max_container_chunks,
       do: {:error, :image_container_too_complex}

  defp parse_webp_chunks(<<>>, dimensions, 1, _count) when dimensions != nil,
    do: {:ok, dimensions}

  defp parse_webp_chunks(
         <<type::binary-size(4), size::little-32, rest::binary>>,
         dimensions,
         images,
         count
       )
       when size <= @max_input_bytes and byte_size(rest) >= size + rem(size, 2) do
    <<data::binary-size(size), _padding::binary-size(rem(size, 2)), tail::binary>> = rest

    case webp_chunk(type, data, dimensions, images) do
      {:ok, next_dimensions, next_images} ->
        parse_webp_chunks(tail, next_dimensions, next_images, count + 1)

      error ->
        error
    end
  end

  defp parse_webp_chunks(_chunks, _dimensions, _images, _count), do: {:error, :invalid_image}

  defp webp_chunk("ANIM", _data, _dimensions, _images),
    do: {:error, :animated_image_not_allowed}

  defp webp_chunk("ANMF", _data, _dimensions, _images),
    do: {:error, :animated_image_not_allowed}

  defp webp_chunk(
         "VP8X",
         <<flags, 0, 0, 0, width_minus_one::little-24, height_minus_one::little-24,
           _rest::binary>>,
         nil,
         0
       ) do
    if (flags &&& 0x02) == 0,
      do: {:ok, {width_minus_one + 1, height_minus_one + 1}, 0},
      else: {:error, :animated_image_not_allowed}
  end

  defp webp_chunk("VP8X", _data, _dimensions, _images), do: {:error, :invalid_image}

  defp webp_chunk(
         "VP8 ",
         <<_frame_tag::binary-size(3), 0x9D, 0x01, 0x2A, width_raw::little-16,
           height_raw::little-16, _rest::binary>>,
         dimensions,
         0
       ) do
    dimensions = dimensions || {width_raw &&& 0x3FFF, height_raw &&& 0x3FFF}
    {:ok, dimensions, 1}
  end

  defp webp_chunk("VP8L", <<0x2F, packed::little-32, _rest::binary>>, dimensions, 0) do
    decoded = {(packed &&& 0x3FFF) + 1, (packed >>> 14 &&& 0x3FFF) + 1}
    {:ok, dimensions || decoded, 1}
  end

  defp webp_chunk(type, _data, dimensions, images)
       when type in ["ALPH", "ICCP", "EXIF", "XMP "] do
    {:ok, dimensions, images}
  end

  defp webp_chunk(_type, _data, _dimensions, _images), do: {:error, :invalid_image}

  defp validate_avif(<<box_size::big-32, "ftyp", rest::binary>>)
       when box_size >= 16 and byte_size(rest) >= box_size - 8 do
    brand_bytes = box_size - 8

    <<major_brand::binary-size(4), _minor_version::binary-size(4),
      compatible::binary-size(brand_bytes - 8), _tail::binary>> = rest

    brands = [major_brand | for(<<brand::binary-size(4) <- compatible>>, do: brand)]

    if "avis" in brands,
      do: {:error, :animated_image_not_allowed},
      else: :ok
  end

  defp validate_avif(_body), do: {:error, :invalid_image}

  defp validate_dimensions({width, height})
       when is_integer(width) and is_integer(height) and width > 0 and height > 0 do
    cond do
      width > @max_dimension or height > @max_dimension ->
        {:error, :image_dimensions_too_large}

      width * height > @max_pixels ->
        {:error, :image_pixel_count_too_large}

      true ->
        :ok
    end
  end

  defp validate_dimensions(_dimensions), do: {:error, :invalid_image}

  defp run_image_task(fun) do
    task = Task.Supervisor.async_nolink(Egregoros.MiniAppImageTaskSupervisor, fun)
    timeout_ms = processing_timeout_ms() + @task_grace_ms

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, _reason} -> {:error, :invalid_image}
      nil -> {:error, :image_processing_timeout}
    end
  rescue
    RuntimeError -> {:error, :image_processing_unavailable}
  catch
    :exit, _reason -> {:error, :image_processing_unavailable}
  end

  defp sanitize_in_worker(body, content_type) do
    with {:ok, runtime} <- worker_runtime(),
         {:ok, directory} <- make_private_directory() do
      try do
        input_path = Path.join(directory, "input")
        output_path = Path.join(directory, "output.webp")

        with :ok <- write_private_file(input_path, body),
             :ok <- run_worker(runtime, directory, input_path, output_path, content_type),
             {:ok, encoded} <- read_worker_output(output_path),
             :ok <- validate_output(encoded) do
          {:ok, %{body: encoded, content_type: @output_content_type}}
        end
      after
        _ = File.rm_rf(directory)
      end
    end
  end

  defp worker_runtime do
    with {:unix, _name} <- :os.type(),
         {:ok, private_dir} <- private_dir(),
         python when is_binary(python) <- configured_executable(:mini_app_image_python, "python3"),
         decoder when is_binary(decoder) <- configured_decoder(),
         kill when is_binary(kill) <- configured_executable(:mini_app_image_kill, "kill"),
         :ok <- validate_executable(python),
         :ok <- validate_decoder(decoder),
         :ok <- validate_executable(kill),
         script =
           Application.get_env(
             :egregoros,
             :mini_app_image_worker_script,
             Path.join(private_dir, "mini_app_image_worker.py")
           ),
         policy_dir = Path.join(private_dir, "mini_app_image_policy"),
         :ok <- validate_regular_file(script),
         :ok <- validate_directory(policy_dir) do
      {:ok,
       %{python: python, decoder: decoder, kill: kill, script: script, policy_dir: policy_dir}}
    else
      _ -> {:error, :image_processing_unavailable}
    end
  end

  defp private_dir do
    case :code.priv_dir(:egregoros) do
      directory when is_list(directory) -> {:ok, List.to_string(directory)}
      _ -> {:error, :image_processing_unavailable}
    end
  end

  defp configured_executable(key, fallback_name) do
    case Application.get_env(:egregoros, key) do
      value when is_binary(value) and value != "" -> value
      _ -> System.find_executable(fallback_name)
    end
  end

  defp configured_decoder do
    case Application.get_env(:egregoros, :mini_app_image_decoder) do
      value when is_binary(value) and value != "" -> value
      _ -> System.find_executable("magick") || System.find_executable("convert")
    end
  end

  defp validate_decoder(path) do
    if Path.basename(path) in ["magick", "convert"],
      do: validate_executable(path),
      else: {:error, :image_processing_unavailable}
  end

  defp validate_executable(path) when is_binary(path) do
    with true <- Path.type(path) == :absolute,
         {:ok, %File.Stat{type: :regular, mode: mode}} <- File.stat(path),
         true <- (mode &&& 0o111) != 0 do
      :ok
    else
      _ -> {:error, :image_processing_unavailable}
    end
  end

  defp validate_executable(_path), do: {:error, :image_processing_unavailable}

  defp validate_regular_file(path) do
    if is_binary(path) and Path.type(path) == :absolute do
      case File.stat(path) do
        {:ok, %File.Stat{type: :regular}} -> :ok
        _ -> {:error, :image_processing_unavailable}
      end
    else
      {:error, :image_processing_unavailable}
    end
  end

  defp validate_directory(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      _ -> {:error, :image_processing_unavailable}
    end
  end

  defp make_private_directory(attempts \\ 3)

  defp make_private_directory(0), do: {:error, :image_processing_unavailable}

  defp make_private_directory(attempts) do
    base = Application.get_env(:egregoros, :mini_app_image_tmp_dir, System.tmp_dir!())

    with true <- is_binary(base) and Path.type(base) == :absolute,
         :ok <- validate_directory(base) do
      suffix = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
      path = Path.join(base, "egregoros-miniapp-image-#{suffix}")

      case File.mkdir(path) do
        :ok ->
          case File.chmod(path, 0o700) do
            :ok ->
              {:ok, path}

            _ ->
              _ = File.rmdir(path)
              {:error, :image_processing_unavailable}
          end

        {:error, :eexist} ->
          make_private_directory(attempts - 1)

        _ ->
          {:error, :image_processing_unavailable}
      end
    else
      _ -> {:error, :image_processing_unavailable}
    end
  end

  defp write_private_file(path, body) do
    case File.open(path, [:write, :binary, :exclusive], fn file -> IO.binwrite(file, body) end) do
      {:ok, :ok} -> File.chmod(path, 0o600)
      _ -> {:error, :image_processing_unavailable}
    end
  end

  defp run_worker(runtime, directory, input_path, output_path, content_type) do
    args = [
      "-I",
      "-B",
      runtime.script,
      runtime.decoder,
      runtime.policy_dir,
      directory,
      image_format(content_type),
      input_path,
      output_path
    ]

    port =
      Port.open({:spawn_executable, runtime.python}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        {:line, @port_line_bytes},
        {:args, args}
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    timeout_ms = processing_timeout_ms()
    started_at = System.monotonic_time(:millisecond)
    startup_deadline = started_at + min(@startup_timeout_ms, timeout_ms)
    processing_deadline = started_at + timeout_ms

    try do
      case await_worker_ready(port, <<>>, startup_deadline) do
        {:ok, diagnostics} ->
          case await_worker_exit(port, diagnostics, processing_deadline) do
            {:ok, 0} ->
              finish_worker(:ok, port, runtime.kill, os_pid, true)

            {:ok, _status} ->
              finish_worker({:error, :invalid_image}, port, runtime.kill, os_pid, true)

            {:error, :worker_output_too_large} ->
              finish_worker({:error, :invalid_image}, port, runtime.kill, os_pid, false)

            {:error, :timeout} ->
              finish_worker(
                {:error, :image_processing_timeout},
                port,
                runtime.kill,
                os_pid,
                false
              )
          end

        {:error, :timeout} ->
          finish_worker(
            {:error, :image_processing_unavailable},
            port,
            runtime.kill,
            os_pid,
            false,
            :process
          )

        {:error, _reason} ->
          finish_worker(
            {:error, :image_processing_unavailable},
            port,
            runtime.kill,
            os_pid,
            false,
            :process
          )
      end
    after
      close_port(port)
    end
  rescue
    _error -> {:error, :image_processing_unavailable}
  catch
    :exit, _reason -> {:error, :image_processing_unavailable}
  end

  defp await_worker_ready(port, buffer, deadline) do
    timeout = remaining_ms(deadline)

    if timeout == 0 do
      {:error, :timeout}
    else
      receive do
        {^port, {:data, framed_data}} ->
          combined = buffer <> port_data(framed_data)

          cond do
            byte_size(combined) > @max_worker_diagnostics_bytes ->
              {:error, :worker_output_too_large}

            String.starts_with?(combined, "READY\n") ->
              {:ok, binary_part(combined, 6, byte_size(combined) - 6)}

            byte_size(combined) >= 6 ->
              {:error, :invalid_worker_handshake}

            true ->
              await_worker_ready(port, combined, deadline)
          end

        {^port, {:exit_status, _status}} ->
          {:error, :worker_exited}
      after
        timeout -> {:error, :timeout}
      end
    end
  end

  defp await_worker_exit(port, diagnostics, deadline) do
    timeout = remaining_ms(deadline)

    if timeout == 0 do
      {:error, :timeout}
    else
      receive do
        {^port, {:data, framed_data}} ->
          diagnostics = diagnostics <> port_data(framed_data)

          if byte_size(diagnostics) > @max_worker_diagnostics_bytes,
            do: {:error, :worker_output_too_large},
            else: await_worker_exit(port, diagnostics, deadline)

        {^port, {:exit_status, status}} when is_integer(status) ->
          {:ok, status}
      after
        timeout -> {:error, :timeout}
      end
    end
  end

  defp remaining_ms(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 0)
  end

  defp port_data({:eol, data}) when is_binary(data), do: data <> "\n"
  defp port_data({:noeol, data}) when is_binary(data), do: data
  defp port_data(data) when is_binary(data), do: data
  defp port_data(_data), do: :binary.copy(<<0>>, @max_worker_diagnostics_bytes + 1)

  defp finish_worker(result, port, kill, os_pid, exited?, target \\ :group) do
    signal_result = terminate(kill, os_pid, target)

    cleanup_result =
      cond do
        exited? -> :ok
        signal_result == :ok -> await_worker_termination(port)
        true -> await_worker_termination(port, 0)
      end

    if cleanup_result == :ok,
      do: result,
      else: {:error, :image_worker_cleanup_failed}
  end

  defp terminate(kill, os_pid, target) do
    pid = if target == :group, do: "-#{os_pid}", else: Integer.to_string(os_pid)

    case System.cmd(kill, ["-KILL", "--", pid], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {_output, _status} -> {:error, :kill_failed}
    end
  rescue
    _error -> {:error, :kill_failed}
  end

  defp await_worker_termination(port, timeout_ms \\ @cleanup_timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_worker_termination(port, deadline)
  end

  defp do_await_worker_termination(port, deadline) do
    timeout = remaining_ms(deadline)

    receive do
      {^port, {:exit_status, _status}} ->
        :ok

      {^port, {:data, _data}} ->
        do_await_worker_termination(port, deadline)
    after
      timeout ->
        if Port.info(port), do: {:error, :worker_still_running}, else: :ok
    end
  end

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp processing_timeout_ms do
    case Application.get_env(:egregoros, :mini_app_image_processing_timeout_ms) do
      timeout when is_integer(timeout) and timeout in 50..@processing_timeout_ms -> timeout
      _ -> @processing_timeout_ms
    end
  end

  defp image_format("image/png"), do: "PNG"
  defp image_format("image/jpeg"), do: "JPEG"
  defp image_format("image/webp"), do: "WEBP"
  defp image_format("image/avif"), do: "AVIF"

  defp read_worker_output(path) do
    with {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_output_bytes <-
           File.lstat(path),
         {:ok, encoded} when byte_size(encoded) <= @max_output_bytes <- File.read(path) do
      {:ok, encoded}
    else
      {:ok, %File.Stat{size: size}} when size > @max_output_bytes ->
        {:error, :sanitized_image_too_large}

      _ ->
        {:error, :invalid_image}
    end
  end

  defp validate_output(encoded) when is_binary(encoded) do
    with {:ok, @output_content_type} <- detect_content_type(encoded),
         :ok <- validate_webp(encoded) do
      :ok
    else
      _ -> {:error, :invalid_image}
    end
  end
end
