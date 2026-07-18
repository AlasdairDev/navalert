# Transit Data Attribution

NavAlert's commute guide uses Metro Manila public-transport route and stop data
from the **Philippine GTFS feed** owned and maintained by the Philippine
**Department of Transportation (DOTC/DOTr)**, released for the Philippine Transit
App Challenge and republished (in modified form) by **Sakay.ph**:

- Source: https://github.com/sakayph/gtfs
- Owner: Department of Transportation and Communications (DOTC)

The data is used under the DOTC Developer License Agreement, which grants a
limited, non-exclusive license to use, reproduce, and distribute the data "for
the sole purpose of assisting mass transportation riders or in furtherance of
promoting public transportation." NavAlert is a non-commercial academic capstone
that assists PUV commuters, squarely within this permitted purpose.

All rights in the underlying data remain with DOTC. This bundled file
(`routes.json.gz`) is a compact, derived subset (jeepney and bus routes with
their ordered stops) produced by `tool/gen_gtfs.py`. It is a **stopgap** dataset
used until fresher official GTFS is available; regenerate with the tool when
newer data is obtained.
