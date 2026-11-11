import logging
import sys

from dotenv import load_dotenv

from common import ROOT, load_tickers
from sec import ingest_ciks, ingest_fundamentals
from tiingo import ingest_prices

log = logging.getLogger("ingest")


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s")
    load_dotenv(ROOT / ".env")
    tickers = load_tickers()
    log.info("%d tickers in registry", len(tickers))
    failures = ingest_ciks(tickers) + ingest_prices(tickers) + ingest_fundamentals(tickers)
    if failures:
        log.error("finished with %d failures", failures)
        sys.exit(1)
    log.info("done")
