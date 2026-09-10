defmodule PhoenixAssetPipeline.Assets.Images do
  @moduledoc false

  alias PhoenixAssetPipeline.Cache
  alias PhoenixAssetPipeline.Config
  alias Vix.Vips.Image
  alias Vix.Vips.Operation

  @cache_file "image_assets.term"
  @image_exts ~w(.avif .jpeg .jpg .png .webp)
  @png_options [compression: 9, keep: [:VIPS_FOREIGN_KEEP_NONE]]
  @avif_options [compression: :VIPS_FOREIGN_HEIF_COMPRESSION_AV1, effort: 9, keep: [:VIPS_FOREIGN_KEEP_NONE]]
  @avif_1x_options [Q: 82] ++ @avif_options
  @avif_high_density_options [Q: 55] ++ @avif_options
  @webp_options [Q: 88, keep: [:VIPS_FOREIGN_KEEP_NONE]]

  def build(assets_dir, asset_terms) do
    cache = read_cache()

    {sources, missing, next_cache} =
      Enum.reduce(asset_terms, {[], %{}, %{}}, fn
        {:asset, "img/" <> relative, digest, content}, {sources, missing, next_cache} ->
          case source?(relative) and Map.fetch(cache, digest) do
            {:ok, variants} ->
              {[{relative, digest} | sources], missing, Map.put(next_cache, digest, variants)}

            :error ->
              path = Path.join([assets_dir, "img", relative])

              {[{relative, digest} | sources], Map.put_new(missing, digest, {content, path}), next_cache}

            false ->
              {sources, missing, next_cache}
          end

        _, state ->
          state
      end)

    next_cache =
      Enum.reduce(missing, next_cache, fn {digest, {content, path}}, cache ->
        Map.put(cache, digest, image_assets(path, content))
      end)

    if map_size(missing) != 0 or map_size(cache) != map_size(next_cache), do: save_cache(next_cache)

    assets =
      sources
      |> Enum.reduce([], fn {relative, digest}, assets ->
        prepend_assets(assets, Map.fetch!(next_cache, digest), relative)
      end)
      |> Enum.sort()

    ensure_unique_assets!(assets)
    assets
  end

  @doc false
  def signature(asset_terms) when is_list(asset_terms) do
    if Enum.any?(asset_terms, &image_source_term?/1),
      do: {:image_build, cache_fingerprint()},
      else: :no_image_build
  end

  defp auto_orient!(image, path) do
    case Operation.autorot(image) do
      {:ok, {image, _orientation}} -> image
      {:error, reason} -> raise "could not auto-orient image #{path}: #{inspect(reason)}"
    end
  end

  defp cache_fingerprint do
    {
      Application.spec(:vix, :vsn),
      Vix.Vips.version(),
      __MODULE__.module_info(:md5),
      Config.image_densities(),
      Config.image_max_pixels()
    }
  end

  defp cache_path, do: Path.join(Config.manifest_cache_dir(), @cache_file)

  defp density_suffix(1), do: ""
  defp density_suffix(density), do: "-#{density}x"

  defp ensure_pixel_limit!(image, path) do
    pixels = Image.width(image) * Image.height(image)

    if pixels > Config.image_max_pixels() do
      raise "could not load image #{path}: #{pixels} pixels exceeds configured limit of #{Config.image_max_pixels()}"
    end
  end

  defp ensure_unique_assets!([]), do: :ok
  defp ensure_unique_assets!([_]), do: :ok

  defp ensure_unique_assets!([first, second | assets]) do
    if elem(first, 0) == elem(second, 0) do
      raise ArgumentError,
            "multiple source images produce #{inspect(elem(first, 0))}; keep only one source extension for each relative image path"
    end

    ensure_unique_assets!([second | assets])
  end

  defp image_assets(path, content) do
    image = load_image!(path, content)
    ensure_pixel_limit!(image, path)
    image = auto_orient!(image, path)
    densities = Config.image_densities()
    max_density = List.last(densities)

    Enum.map(densities, fn density ->
      variant = resize!(image, density / max_density, path)

      {density, write_image!(variant, ".png", @png_options),
       write_avif!(
         variant,
         if(density == 1, do: @avif_1x_options, else: @avif_high_density_options)
       ), write_image!(variant, ".webp", @webp_options)}
    end)
  end

  defp image_source_term?({:asset, "img/" <> relative, _}), do: source?(relative)
  defp image_source_term?({:asset, "img/" <> relative, _, _}), do: source?(relative)
  defp image_source_term?(_), do: false

  defp load_image!(path, content) do
    case Image.new_from_buffer(content) do
      {:ok, image} -> image
      {:error, reason} -> raise "could not load image #{path}: #{inspect(reason)}"
    end
  end

  defp prepend_assets(assets, variants, relative) do
    base = "assets/img/" <> Path.rootname(relative)

    Enum.reduce(variants, assets, fn {density, png, avif, webp}, assets ->
      base = base <> density_suffix(density)

      [
        {base <> ".webp", webp},
        {base <> ".avif", avif},
        {base <> ".png", png}
        | assets
      ]
    end)
  end

  defp read_cache do
    Cache.read_term(cache_path(), %{}, fn
      {fingerprint, cache} when is_map(cache) ->
        if fingerprint == cache_fingerprint(), do: {:ok, cache}, else: :error

      _ ->
        :error
    end)
  end

  defp resize!(image, 1.0, _path), do: image

  defp resize!(image, scale, path) do
    case Operation.resize(image, scale, kernel: :VIPS_KERNEL_LANCZOS3) do
      {:ok, image} -> image
      {:error, reason} -> raise "could not resize image #{path}: #{inspect(reason)}"
    end
  end

  defp save_cache(cache), do: Cache.write_term!(cache_path(), {cache_fingerprint(), cache})

  defp source?(path) do
    path |> Path.extname() |> String.downcase() |> Kernel.in(@image_exts)
  end

  # libvips writes pHYs even with keep: none. Stop before the compressed image data.
  defp strip_png_resolution(content, offset \\ 8) do
    case binary_part(content, offset, 8) do
      <<9::32, "pHYs">> ->
        binary_part(content, 0, offset) <>
          binary_part(content, offset + 21, byte_size(content) - offset - 21)

      <<_::32, "IDAT">> ->
        content

      <<size::32, _::32>> ->
        strip_png_resolution(content, offset + size + 12)
    end
  end

  defp write_avif!(image, opts) do
    case Operation.heifsave_buffer(image, opts) do
      {:ok, content} -> content
      {:error, reason} -> raise "could not write .avif image: #{inspect(reason)}"
    end
  end

  defp write_image!(image, suffix, opts) do
    case Image.write_to_buffer(image, suffix, opts) do
      {:ok, content} when suffix == ".png" -> strip_png_resolution(content)
      {:ok, content} -> content
      {:error, reason} -> raise "could not write #{suffix} image: #{inspect(reason)}"
    end
  end
end
