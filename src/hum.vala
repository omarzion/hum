/*
 * hum.vala
 * This file is part of Hum, and is thus awesome.
 *
 * Copyright (C) 2007-2009 by Brian Davis
 *
 * Hum is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * Hum is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with Hum; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin St, Fifth Floor, 
 * Boston, MA  02110-1301  USA
 */

using GLib;
using DBus;
using Gst;

// FIXME: We'll start w/Gst.Playbin, but for playlist support we should move to
//        Gst.Decodebin in the future (cross-fading, etc.).

// NOTES REGARDING COLLECTIONS THAT I CAN'T FIND A HOME FOR...
//
// Physical URIs will feature the default 'file://' prefix.
// Search URIs will be prefixed with something like 'search://term[+term...]'.
// Tag URIs will be prefixed with something like 'tags://term[+term...]'.

namespace Hum
{
	// This is the player backend.
	[DBus (name = "org.washedup.Hum")]
	public class Player : GLib.Object
	{
		// The application main loop.
		private GLib.MainLoop mainloop;

		// The GStreamer playback pipeline.
		private Gst.Element pipeline { get; set; }

		// The GStreamer communication bus.
		private Gst.Bus bus { get; set; }
		
		// The playlist, which is just a linked list of URIs.
		// FIXME: This should implement some doubly-linked list interface. 
		public GLib.List<string> playlist;

		//////////////
		// SETTINGS //
		//////////////
		
		// FIXME: These settings should probably be persisted using GConf or
		//        something, since users are likely to have a preference.

		// Playlist repeat setting (default: true).
		public bool repeat;

		// Playlist shuffle setting (default: false).
		public bool shuffle;

		// Playlist crossfade setting (default: false).
		public bool crossfade;

		//////////////
		// PLAYBACK //
		//////////////

		// The index of the currently-selected track.
		public int current_track;

		///////////////
		// OPERATION //
		///////////////

		Player (string[] args)
		{
			mainloop = new GLib.MainLoop (null, false);
			
			// FIXME: See the FIXME under SETTINGS, above.
			repeat = true;
			shuffle = false;
			crossfade = false;

			// Initialize the playlist pointer to the top of the list.
			current_track = 0;

			// Initialize GStreamer.
			Gst.init(ref args);
			
			message ("GStreamer library initialized.");
			
			// Set up the pipeline for playing and the bus for messages.
			pipeline = ElementFactory.make ("playbin", "pipeline");
			bus = pipeline.get_bus ();
			bus.add_watch (bus_callback);
			pipeline.set_state (Gst.State.READY);
			
			message ("Player instantiated.");

			register_dbus_service ();
		}

		// Run the application.
		public void run ()
		{
			mainloop.run ();
		}

		// Tear down the application.
		public void quit ()
		{
			message ("Quitting...");

			pipeline.set_state (Gst.State.NULL);
			
			message ("Goodbye!");

			mainloop.quit ();
		}

		// The master callback that intercepts messages on the pipeline's bus.
		private bool bus_callback (Gst.Bus bus, Gst.Message message)
		{
			switch (message.type)
			{
				case Gst.MessageType.ERROR:
					GLib.Error err;
					string debug;
					message.parse_error (out err, out debug);
					stderr.printf ("Error: %s\n", err.message);
					break;
				case MessageType.EOS:
					next();
					break;
				case MessageType.STATE_CHANGED:
				case MessageType.TAG:
				default:
					break;
			}

			return true;
		}

		// Register Hum as a DBus service.
		private void register_dbus_service ()
		{
			try
			{
				var conn = DBus.Bus.get (DBus.BusType.SESSION);

				dynamic DBus.Object bus = conn.get_object ("org.freedesktop.DBus",
				                                           "/org/freedesktop/DBus",
									   "org.freedesktop.DBus");

				uint request_name_result = bus.request_name ("org.washedup.Hum", (uint) 0);

				if (request_name_result == DBus.RequestNameReply.PRIMARY_OWNER)
				{
					conn.register_object ("/org/washedup/Hum", this);
					
					message ("Successfully registered DBus service!");
					
					run ();
				}

				else
				{
					quit ();
				}
			}

			catch (DBus.Error e)
			{
				stderr.printf ("Shit! %s\n", e.message);
			}
		}

		///////////
		// ORDER //
		///////////

		// Append a new track to the playlist or, if *position* is specified, insert a new
		// track at position *position* in the playlist.
		public void add (string uri, int position = -1)
		{
			if (position == -1)
			{
				playlist.append (uri);
				
				message ("appended '%s' to the playlist", uri);
			}
			
			else
			{
				playlist.insert (uri, position);
				
				message ("inserted '%s' at position %d in the playlist", uri, position);
			}
			
			// If we add something ahead of the currently-selected track, its position
			// changes.
			if (position <= current_track)
			{
				current_track += 1;
			}
			
		}

		// Delete the track at position *position* from the playlist.
		public void remove (int position)
		{
			if (position == current_track && pipeline.current_state == Gst.State.PLAYING)
			{
				stop ();
			}

			playlist.remove (playlist.nth_data (position));

			// If we remove something ahead of the currently-selected track, its
			// position changes.
			if (position < current_track)
			{
				current_track -= 1;
			}
			
			message ("removed the track at position %d from the playlist", position);
		}

		// Move a track from position *from_position* to *to_position* in the playlist.
		public void move (int from_position, int to_position)
		{
			string uri = playlist.nth_data (from_position);

			// Actually perform the move.
			remove (from_position);
			add (uri, to_position);
			
			message ("moved the track at position %d to position %d within the playlist", from_position, to_position);
		}

		// Remove the contents of the playlist.
		public void clear ()
		{
			stop ();
			playlist = new GLib.List<string> ();
			
			message ("cleared the playlist");
		}

		// Return the contents of the playlist.
		// FIXME: Investigate using GLib.Array or something for *playlist* that is
		//        faster, smaller, less unweildy, and fits this model better.
		public string[] get_playlist ()
		{
			string[] list = new string[playlist.length ()];

			for (int i = 0; i < playlist.length (); i++)
			{
				list[i] = playlist.nth_data (i);
			}

			return list;
		}

		//////////////
		// PLAYBACK //
		//////////////

		// Start playback of the items in the playlist. If playback is paused, resume
		// playing the selected track. If *position* is specified, begin playback at *position*
		// position in the playist. Otherwise, start at the beginning.
		public void play (int position = -1)
		{
			if (position == -1)
			{
				var current_state = pipeline.current_state;

				if (current_state == Gst.State.PAUSED)
				{
					pipeline.set_state (Gst.State.PLAYING);

					message ("resuming playback of the track at position %d", current_track);
				}
				
				else if (current_state == Gst.State.READY)
				{
					play (0);
				}
			}
			
			else
			{
				// NOTE: This results in a reassignment (current_track = 0, then position).
				stop ();
				current_track = position;
				pipeline.set ("uri", playlist.nth_data (current_track));
				pipeline.set_state (Gst.State.PLAYING);
			
				message ("playing the track at position %d", current_track);
			}
		}

		// Pause playback.
		public void pause ()
		{
			pipeline.set_state (Gst.State.PAUSED);
			
			message ("paused playback");
		}

		// Halt playback, resetting the playback pointer to the first item in the
		// playlist.
		public void stop ()
		{
			current_track = 0;
			pipeline.set_state (Gst.State.READY);
			
			message ("stopped playback");
		}

		// Play the next track in the playlist. If the current track is the last
		// track in the playlist and looping is enabled, play the first track in the
		// playlist.
		public void next ()
		{
			if (current_track == playlist.length () - 1)
			{
				if (repeat)
				{
					play (0);
				}
			}

			else
			{
				play (current_track + 1);
			}

			message ("skipped to the next track in the playlist at position %d", current_track);
		}

		// Play the previous track in the playlist. If the current track is the
		// first track in the playlist and looping is enabled, play the last track in
		// the playlist.
		public void previous ()
		{
			if (current_track == 0)
			{
				if (repeat)
				{
					play ((int) playlist.length () - 1);
				}
			}

			else
			{
				play (current_track - 1);
			}

			message ("skipped to the previous track in the playlist at position %d", current_track);
		}

		// Seek to *usec* in the currently-playing track. If no track is playing, do
		// nothing.
		public void seek (int64 usec)
		{
			pipeline.seek_simple (Gst.Format.TIME, Gst.SeekFlags.FLUSH, usec);
			
			float sec = (float) usec / 1000000000;
			message ("seeked to %f seconds", sec);
		}

		// Return the currently selected track.
		public int get_current_track ()
		{
			return current_track;
		}

		// Return the current track progress in usec.
		public int64 get_progress ()
		{
			int64 position;
			Gst.Format format = Gst.Format.TIME;

			if (pipeline.query_position (ref format, out position))
			{
				return position;
			}
			
			else
			{
				return -1;
			}
		}

		// Return the current playback state.
		public Gst.State get_state ()
		{
			return pipeline.current_state;
		}

		// Adjust playback volume.
		public void set_volume (int level)
		{
			// FIXME: How do you do this?
		}

		// Query playback volume.
		public int get_volume ()
		{
			// FIXME: And how do you do this?
			return 0;
		}

		//////////////
		// SETTINGS //
		//////////////

		// Toggle playlist looping.
		public void set_repeat (bool do_repeat)
		{
			repeat = do_repeat;

			if (repeat)
			{
				message ("playlist repeat toggled on");
			}

			else
			{
				message ("playlist repeat toggled off");
			}
		}

		// Return the current repeat setting.
		public bool get_repeat ()
		{
			return repeat;
		}

		// Toggle playlist shuffle.
		// FIXME: Make this work!
		public void set_shuffle (bool do_shuffle)
		{
			shuffle = do_shuffle;
		}

		// Return the current shuffle setting.
		public bool get_shuffle ()
		{
			return shuffle;
		}

		// Toggle playlist crossfading.
		// FIXME: Make this work!
		public void set_crossfade (bool do_crossfade)
		{
			crossfade = do_crossfade;
		}

		// Return the current crossfade setting.
		public bool get_crossfade ()
		{
			return crossfade;
		}

		///////////////
		// EXECUTION //
		///////////////
		
		static int main (string[] args)
		{
			new Player(args);

			return 0;
		}
	}
}
