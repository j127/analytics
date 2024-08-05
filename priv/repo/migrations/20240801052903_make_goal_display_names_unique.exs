defmodule Plausible.Repo.Migrations.AddGoalDisplayName do
  use Ecto.Migration

  def change do
    alter table(:goals) do
      modify :display_name, :text, null: false
    end
  end
end
