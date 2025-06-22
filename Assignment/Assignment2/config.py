import os

variable_which_i_wont_use = "this is a variable which i wont use"


class Config:
    SQLALCHEMY_DATABASE_URI = os.getenv("DB_LINK")
    SQLALCHEMY_TRACK_MODIFICATIONS = False

# DB_LINK='postgresql://postgres:password@db:5432/mydb'

# DB_LINK='postgresql://{username}:{password}@{host}:{port}/{databasename}'