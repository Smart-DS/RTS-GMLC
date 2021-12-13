import logging
import json
import os
from pathlib import Path

from pydantic import DataModel, Field

logger = logging.getLogger(__name__)


class BidDSJsonBaseModel(BaseModel):
    """Base data model for all dsgrid data models"""

    class Config:
        title = "BidDSJsonModel"
        anystr_strip_whitespace = True
        validate_assignment = True
        validate_all = True
        extra = "forbid"
        use_enum_values = False
        arbitrary_types_allowed = True
        allow_population_by_field_name = True

    @classmethod
    def load(cls, filename):
        """Load a data model from a file.
        Temporarily changes to the file's parent directory so that Pydantic
        validators can load relative file paths within the file.
        Parameters
        ----------
        filename : str
        """
        filename = Path(filename)
        base_dir = filename.parent.absolute()
        orig = os.getcwd()
        os.chdir(base_dir)
        try:
            cfg = cls(**load_data(filename.name))
            return cfg
        except ValidationError:
            logger.exception("Failed to validate %s", filename)
            raise
        finally:
            os.chdir(orig)

    @classmethod
    def schema_json(cls, by_alias=True, indent=None) -> str:
        data = cls.schema(by_alias=by_alias)
        return json.dumps(data, indent=indent, cls=ExtendedJSONEncoder)

# An Option: Translate formulation schema into Pydantic models, can output 
# overall formulation as json schema if that's helpful for others.
# Question: Are there other/better options we should consider?

class Model(BidDSJsonBaseModel):

    network: Network = Field(
        title="network"
    )
    scenario: Scenario = Field(
        title="scenario"
    )


class Network(BidDSJsonBaseModel):

    generators: List[Generator] = Field(
        title="generators"
    )


class Scenario(BidDSJsonBaseModel): pass



class Generator(BidDSJsonBaseModel):

    uid: str = Field(
        title="uid"
    )
    bus: str = Field(
        title="bus"
    )


def load_data(filename, **kwargs):
    """Load data from the file.
    Supports JSON, TOML, or custom via kwargs.
    Parameters
    ----------
    filename : str
    Returns
    -------
    dict
    """
    with open(filename) as f_in:
        try:
            data = json.load(f_in)
        except Exception:
            logger.exception("Failed to load data from %s", filename)
            raise

    logger.debug("Loaded data from %s", filename)
    return data


def dump_data(data, filename, **kwargs):
    """Dump data to the filename.
    Supports JSON, TOML, or custom via kwargs.
    Parameters
    ----------
    data : dict
        data to dump
    filename : str
        file to create or overwrite
    """
    with open(filename, "w") as f_out:
        json.dump(data, f_out, **kwargs)

    logger.debug("Dumped data to %s", filename)