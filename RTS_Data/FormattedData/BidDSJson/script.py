from pathlib import Path

from .datamodel import *

rts_path = Path(__file__).parent.parent.parent
source_path = rts_path / "SourceData"

if __name__ == "__main__":    

    # Open Source Data .csv files one by one and create data model objects
    generators = []
    with open(source_path / "gen.csv", "r") as f:
        # for each line of gen.csv, make a Generator object
        # Question: Loop through and map explicitly, or do something more elegant?
        generators.append(Generator())
        pass

    model = Model(
        Network(generators), 
        Scenario())
    