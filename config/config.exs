import Config

config :phoenix_asset_pipeline, otp_app: :phoenix_asset_pipeline

if config_env() == :prod do
  config :phoenix_asset_pipeline, precompiled_manifest: true
end
