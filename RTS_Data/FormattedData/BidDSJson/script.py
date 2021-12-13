from pathlib import Path

import pandas as pd

from datamodel import *

here = Path(__file__).parent
rts_path = here.parent.parent
source_path = rts_path / "SourceData"

if __name__ == "__main__":

    # Open Source Data .csv files one by one and create data model objects
    gen_map = {
        "GEN UID": "uid",
        "Bus ID": "bus"
    }
    generators = []
    df = pd.read_csv(source_path / "gen.csv")
    df = df[[col for col in gen_map.keys()]]
    df.rename(columns=gen_map, inplace=True)
    for ind, gen in df.iterrows():
        generators.append(Generator(**gen.to_dict()))

    model = Model(
        network=Network(generators=generators), 
        scenario=Scenario())
    
    with open(here / "rts-gmlc.json", "w") as f:
        f.write(model.json(indent=4))

    with open(here / "schema.json", "w") as f:
        f.write(Model.schema_json(indent=4))
        