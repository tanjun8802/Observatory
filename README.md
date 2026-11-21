# Observatory

A native Mac dashboard for a personal watchlist, scheduled Codex feeds, and on-demand questions. Requires macOS 14 or later.

## Using your dashboard

Type a question into **Ask Codex** and press **⌘ Return** to see the answer on the dashboard. It uses the local Codex CLI and its existing ChatGPT sign-in. If necessary, run `codex login` first. Dashboard queries run as independent read-only requests with web search available. Choose **Track this answer** beneath a reply to save it as the first reading for a feed. You can set a schedule before saving. Changing the prompt creates a feed for the revised question.

You can also type “Set up a London weather feed every morning at 8, in Celsius” directly into **Ask Codex**. Review the proposed schedule and choose **Add feed**. Weather cards show the location, temperature, condition and a matching symbol. Other measurable feeds show labeled values and units. Open **Full reading** for the details or follow the source link. Existing Codex feeds pick up the new presentation on their next successful run.

New feeds use square tiles, four across. Choose **Details** on a compact tile for its full reading, source, and timestamps. Choose **Arrange** above your feeds. In **All**, **Fit squares** packs the entire board into equal squares. Drag **Move** to an open grid position and drag the lower-right resize handle to change a card’s width and height. The **Layout** menu offers the same controls by keyboard. Choose **Done** to leave arrangement mode. Observatory saves each change and restores it when you reopen the dashboard.

Use **Theme** in the sidebar to choose Evergreen, Midnight, Paper, Console, Coral, Terrazzo, or Tide. Observatory remembers your choice. To give one feed its own theme, open its **••• → Feed theme** menu. Choose **Use dashboard theme** to follow the sidebar setting again.

Choose **Add feed → Describe with Codex**, and enter a request such as “Every day at 8 am, summarise the weather in London.” Choose **Draft feed**, review or edit the task and timing, then choose **Add feed**. You can run a feed on demand, once at a chosen time, daily at a local time, or every 1 to 10,080 minutes. Daily, interval, and on-demand feeds get an initial reading when saved. A one-time feed waits for its scheduled time. A Codex card shows its last success and next run. Open its actions menu to edit the prompt or schedule, pause it, or resume it. **Run now** fetches a single update even while the schedule is paused.

The Brixworth current-weather feed uses Open-Meteo’s timestamped model estimate. WCA Live Results reads the official competition API, with direct result links under Full reading. Codex Token Usage reads cumulative counters from the local Codex thread index on refresh. Its scope is retained local sessions. Choose **Retry failed** above the grid to retry the unpaused feeds with errors in the current view.

For a stock, flight, or JSON source, select **Data provider** in the same sheet. Each card keeps the last successful reading and shows when the app checked its source.

| Monitor | What to enter | Data source |
| --- | --- | --- |
| Stock | A ticker such as AAPL | Finnhub quote with the provider’s market timestamp |
| Flight | Departure and arrival airport codes, date, currency, and optional nonstop flight number | Lowest one-way fare returned for the route or specified flight |
| JSON field | A public HTTPS endpoint and a field path such as metadata.count | The chosen endpoint, checked directly from your Mac |

For stocks or flights, **Configure…** in the feed editor shows where to get and save the provider key. If a saved feed needs credentials, choose **Connect Finnhub** or **Connect SerpApi** on its card. Saving a replacement key retries affected feeds. Quotes depend on market hours and the coverage of your Finnhub account. Flight offers can change before booking and each fresh SerpApi search uses your account quota. Provider credentials are saved in macOS Keychain.

To try a feed without an account, choose **Add feed → Data provider → JSON field → Try the USGS earthquake feed → Add feed**. The card shows the number of significant earthquakes the US Geological Survey reported in the past month.

The app checks data-provider feeds at launch and on wake. Codex feeds catch up on due runs when the app reopens or the Mac wakes. **Refresh** runs all unpaused feeds immediately. While running, Observatory checks stocks and custom feeds about every five minutes and flights about once an hour. Closing the window keeps Observatory running. Quitting stops refreshes until you open it again. To have it start after a restart, add Observatory under **System Settings → General → Login Items**.

Your watchlist and cached readings are stored in `~/Library/Application Support/Observatory/board.json`. The clock and scheduled times use your local time zone.

## Building

With the Swift 6.3 Command Line Tools on macOS, run:

```sh
./scripts/build-app.sh
open .build/Observatory.app
```

The script creates an ad-hoc signed application bundle. Run the automated checks with `./scripts/test.sh`.
