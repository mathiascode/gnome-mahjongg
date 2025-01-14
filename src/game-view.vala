/*
 * Copyright (C) 2010-2013 Robert Ancell
 *
 * This program is free software: you can redistribute it and/or modify it under
 * the terms of the GNU General Public License as published by the Free Software
 * Foundation, either version 2 of the License, or (at your option) any later
 * version. See http://www.gnu.org/copyleft/gpl.html the full text of the
 * license.
 */

public class GameView : Gtk.Widget {
    private int x_offset;
    private int y_offset;
    private int tile_width;
    private int tile_height;
    private int tile_layer_offset_x;
    private int tile_layer_offset_y;
    private int tile_pattern_width;
    private int tile_pattern_height;

    public Gdk.Pixbuf? pixbuf;
    public Gdk.Texture? texture;
    public Cairo.Pattern? cairo_pattern;
    public int initial_theme_width;
    public int initial_theme_height;
    public int loaded_theme_width;
    public int loaded_theme_height;
    private bool using_cairo;
    private bool using_vector;
    private string theme;
    private double theme_aspect;
    private int rendered_theme_width;
    private int rendered_theme_height;

    private Game? _game;
    public Game? game {
        get { return _game; }
        set {
            _game = value;
            if (value == null)
                return;

            _game.redraw_tile.connect (redraw_tile_cb);
            _game.paused_changed.connect (paused_changed_cb);
            update_dimensions ();
            resize_theme ();
            queue_draw ();
        }
    }

    public GameView (bool using_cairo) {
        this.using_cairo = using_cairo;

        var click_controller = new Gtk.GestureClick ();
        this.add_controller (click_controller);
        click_controller.pressed.connect (click_cb);
    }

    public override void size_allocate (int width, int height, int baseline) {
        if (game == null)
            return;

        update_dimensions ();
        resize_theme ();
    }

    public override void snapshot (Gtk.Snapshot snapshot) {
        if (game == null)
            return;

        if (texture == null && cairo_pattern == null)
            return;

        Gsk.RenderNode? texture_node = null;

        /* Scale the tile texture */
        if (texture != null) {
            var texture_snapshot = new Gtk.Snapshot ();
            texture.snapshot (texture_snapshot, rendered_theme_width, rendered_theme_height);

            texture_node = texture_snapshot.free_to_node ();
        }

        foreach (unowned var tile in game.tiles) {
            if (!tile.visible)
                continue;

            /* Select image for this tile, or blank image if paused */
            var tile_number = game.paused ? -1 : tile.number;
            var texture_x = get_image_offset (tile_number) * tile_pattern_width;
            var texture_y = 0;

            if (!game.paused) {
                if ((tile == game.selected_tile) ||
                    (game.hint_blink_counter % 2 == 1 && (tile == game.hint_tiles[0] || tile == game.hint_tiles[1])))
                    texture_y = tile_pattern_height;
            }

            /* Draw the tile */
            int tile_x, tile_y;
            get_tile_position (tile, out tile_x, out tile_y);

            var tile_rect = Graphene.Rect ();
            tile_rect.init (tile_x, tile_y, tile_pattern_width, tile_pattern_height);

            snapshot.push_clip (tile_rect);

            if (texture_node != null) {
                snapshot.translate (Graphene.Point () {
                    x = tile_x - texture_x,
                    y = tile_y - texture_y
                });
                snapshot.append_node (texture_node);
            } else {
                /* Cairo fallback */
                var ctx = snapshot.append_cairo (tile_rect);
                var matrix = Cairo.Matrix.identity ();

                matrix.scale (
                    (double)loaded_theme_width / (double)rendered_theme_width,
                    (double)loaded_theme_height / (double)rendered_theme_height
                );
                matrix.translate (texture_x - tile_x, texture_y - tile_y);

                cairo_pattern.set_matrix (matrix);
                ctx.set_source (cairo_pattern);

                ctx.rectangle (tile_x, tile_y, tile_pattern_width, tile_pattern_height);
                ctx.fill ();
            }
            snapshot.pop ();
        }
    }

    public void set_theme (string? theme_path, GameView? game_view = null, string? fallback_theme_path = null) {
        this.texture = null;
        this.cairo_pattern = null;

        if (theme_path == null) {
            this.pixbuf = null;
            return;
        }

        if (game_view == null) {
            try {
                pixbuf = new Gdk.Pixbuf.from_resource (theme_path);
            } catch (Error e) {
                try {
                    pixbuf = new Gdk.Pixbuf.from_resource (fallback_theme_path);
                } catch (Error e) {
                    warning ("Could not load theme %s: %s", theme_path, e.message);
                    return;
                }
            }
            this.initial_theme_width = pixbuf.width;
            this.initial_theme_height = pixbuf.height;
            this.loaded_theme_width = 0;
            this.loaded_theme_height = 0;
        } else {
            this.pixbuf = game_view.pixbuf;
            this.texture = game_view.texture;
            this.cairo_pattern = game_view.cairo_pattern;
            this.initial_theme_width = game_view.initial_theme_width;
            this.initial_theme_height = game_view.initial_theme_height;
            this.loaded_theme_width = game_view.loaded_theme_width;
            this.loaded_theme_height = game_view.loaded_theme_height;
        }

        this.using_vector = theme_path.has_suffix ("postmodern");
        this.theme_aspect = ((double) this.initial_theme_height / 2) / ((double) this.initial_theme_width / 43);
        this.theme = theme_path;

        resize_theme ();
    }

    private void resize_theme () {
        if (game == null || theme == null)
            return;

        if (rendered_theme_width == 0)
            return;

        /* Get size to load the next tile texture at */
        var new_theme_width = 0;
        var new_theme_height = 0;
        var decreased_size = false;
        var use_original_size = false;

        for (var i = 8; i >= 2; i = i - 2) {
            if (rendered_theme_width < initial_theme_width / i) {
                new_theme_width = initial_theme_width / i;
                new_theme_height = initial_theme_height / i;
                decreased_size = true;
                break;
            }
        }
        if (!decreased_size) {
            while (new_theme_width < rendered_theme_width) {
                if (!using_vector && new_theme_width > initial_theme_width) {
                    new_theme_width = initial_theme_width;
                    new_theme_height = initial_theme_height;
                    use_original_size = true;
                    break;
                }
                new_theme_width += initial_theme_width;
                new_theme_height += initial_theme_height;
            }
        }
        if (!use_original_size) {
            new_theme_width *= scale_factor;
            new_theme_height *= scale_factor;
        }

        if (new_theme_width == loaded_theme_width)
            /* Texture size did not change, nothing to do */
            return;

        /* Load texture at new size */
        this.loaded_theme_width = new_theme_width;
        this.loaded_theme_height = new_theme_height;

        try {
            var pixbuf = this.pixbuf;
            if (!use_original_size) {
                if (new_theme_width > initial_theme_width)
                    pixbuf = new Gdk.Pixbuf.from_resource_at_scale (theme, new_theme_width, new_theme_height, false);
                else
                    pixbuf = pixbuf.scale_simple (new_theme_width, new_theme_height, Gdk.InterpType.TILES);
            }
            var rowstride = new_theme_width * 4;
            var new_texture = new Gdk.MemoryTexture (
                new_theme_width,
                new_theme_height,
                Gdk.MemoryFormat.R8G8B8A8,
                pixbuf.read_pixel_bytes (),
                rowstride
            );

            if (using_cairo) {
                var theme_surface = new Cairo.ImageSurface (Cairo.Format.ARGB32, new_theme_width, new_theme_height);
                new_texture.download (theme_surface.get_data (), rowstride);
                theme_surface.mark_dirty ();
                this.cairo_pattern = new Cairo.Pattern.for_surface (theme_surface);
            } else {
                this.texture = new_texture;
            }
            queue_draw ();
        } catch (Error e) {
            warning ("Could not load theme %s: %s", theme, e.message);
        }
    }

    private void update_dimensions () {
        if (theme == null)
            return;

        var width = get_width ();
        var height = get_height ();

        /* Need enough space for the whole map and one unit border */
        var map_width = game.map.width + 2;
        var map_height = (int) ((game.map.height + 2) * theme_aspect);

        /* Scale the map to fit */
        var unit_width = int.min (width / map_width, height / map_height);
        var unit_height = (int) (unit_width * theme_aspect);

        /* The size of one tile is two units wide, and the correct aspect ratio */
        tile_width = unit_width * 2;
        tile_height = unit_height * 2;

        /* Offset the tiles when on a higher layer (themes must use these hard-coded ratios) */
        tile_layer_offset_x = tile_width / 7;
        tile_layer_offset_y = tile_height / 10;

        /* Center the map */
        x_offset = (width - game.map.width * unit_width) / 2;
        y_offset = (height - game.map.height * unit_height) / 2;

        /* The images are bigger than the tile as they contain the isometric extension in the z-axis */
        tile_pattern_width = tile_width + tile_layer_offset_x;
        tile_pattern_height = tile_height + tile_layer_offset_y;

        /* Store the exact width the theme should be rendered at */
        rendered_theme_width = tile_pattern_width * 43;
        rendered_theme_height = tile_pattern_height * 2;
    }

    private void get_tile_position (Tile tile, out int x, out int y) {
        x = x_offset + tile.slot.x * tile_width / 2 + tile.slot.layer * tile_layer_offset_x;
        y = y_offset + tile.slot.y * tile_height / 2 - tile.slot.layer * tile_layer_offset_y;
    }

    private int get_image_offset (int number) {
        var set = number / 4;

        /* Invalid numbers use the blank tile */
        if (number < 0 || set >= 36)
            return 42;

        /* The bonus tiles have different images for each */
        if (set == 33)
            return 33 + number % 4;
        if (set == 35)
            return 38 + number % 4;

        /* The white dragons are in-between the bonus tiles just to be confusing */
        if (set == 34)
            return 37;

        /* Everything else is in set order */
        return set;
    }

    private void redraw_tile_cb (Tile tile) {
        queue_draw ();
    }

    private void paused_changed_cb () {
        queue_draw ();
    }

    private void click_cb (Gtk.GestureClick _controller, int n_press, double event_x, double event_y) {
        if (game == null)
            return;

        var click_blocked = !game.attempt_move () || game.paused;

        if (click_blocked)
            return;

        /* Get the tile under the square */
        var tile = find_tile ((int) event_x, (int) event_y);

        /* If not a valid tile then ignore the event */
        if (tile == null || !game.tile_can_move (tile))
            return;

        /* Select first tile */
        if (game.selected_tile == null) {
            game.selected_tile = tile;
        }
        /* Unselect tile by clicking on it again */
        else if (tile == game.selected_tile) {
            game.selected_tile = null;
        }
        /* Attempt to match second tile to the selected one */
        else if (tiles_match (game.selected_tile, tile)) {
            game.remove_pair (game.selected_tile, tile);
        }
        else {
            game.selected_tile = tile;
        }

        queue_draw ();
    }

    private Tile? find_tile (int x, int y) {
        unowned Tile? topmost_tile = null;
        var previous_layer = -1;

        foreach (unowned var tile in game.tiles) {
            if (!tile.visible)
                continue;

            int tile_x, tile_y;
            get_tile_position (tile, out tile_x, out tile_y);

            if (tile.slot.layer > previous_layer
                    && tile_x <= x <= (tile_x + tile_pattern_width)
                    && tile_y <= y <= (tile_y + tile_pattern_height))
                topmost_tile = tile;
        }
        return topmost_tile;
    }
}
