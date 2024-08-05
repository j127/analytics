defmodule Plausible.Repo.Migrations.AddGoalDisplayName do
  use Ecto.Migration

  def change do
    create unique_index(:goals, [:site_id, :display_name])

    alter table(:goals) do
      modify :display_name, :text, null: false
    end
  end
end
