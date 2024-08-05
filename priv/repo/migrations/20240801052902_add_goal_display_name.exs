defmodule Plausible.Repo.Migrations.AddGoalDisplayName do
  use Ecto.Migration

  def change do
    alter table(:goals) do
      add :display_name, :text
    end

    fill_display_names()
  end

  def fill_display_names do
    execute """
    UPDATE goals
    SET display_name = 
      CASE
        WHEN page_path IS NOT NULL THEN 'Visit ' || page_path
        WHEN event_name IS NOT NULL THEN event_name
      END
    """
  end
end
