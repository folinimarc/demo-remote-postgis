# Example: Bootstrap a Public PostGIS Database on a remote virtual machine (e.g. DigitalOcean)

## Motivation
Sometimes we want to quickly set up a public PostGIS database for testing or demonstration purposes. This repository provides a bootstrap script to set up a PostgreSQL + PostGIS database on a DigitalOcean droplet, configure it for remote access, and secure it with UFW firewall rules. It also includes an example of importing open geospatial data from Zürich, Switzerland, and running a sample spatial query.

## Setup
0. Prerequisite: This guide assumes you work on a Unix-like system (including Windows WSL2) with `ssh` installed.

1. Prerequisite: Make sure you have a virtual machine available with SSH access for a privileged user. For example, you can create a droplet on [DigitalOcean](https://www.digitalocean.com/) which will provide you with a public IP to connect to.

2. Specify parameters as environment variables in your terminal. We will reference these in the commands below. You can freely choose the values for the PostgreSQL role, password, and database name.
   ```bash
   export MY_DROPLET_ID="your_droplet_ip_or_hostname"
   export MY_POSTGRES_ROLE="your_postgres_role"
   export MY_SECRET_POSTGRES_PASSWORD="your_secure_password"
   export MY_POSTGIS_DB="your_postgis_database"
   ```
3. Run the bootstrap script on the remote server, passing the PostgreSQL role, password, and database parameters. This script installs PostgreSQL, PostGIS, and configures the database and user. It also allocates swap space to improve performance on small droplets and configures UFW firewall to only allow SSH and PostgreSQL access.
   ```bash
   ssh root@$MY_DROPLET_ID "bash -s -- -r $MY_POSTGRES_ROLE -p '$MY_SECRET_POSTGRES_PASSWORD' -d $MY_POSTGIS_DB" < bootstrap.sh
   ```
4. That's it! You should now be able to connect to your remote PostGIS database using a PostGIS-compatible client, such as `psql` or `pgAdmin`.


## Sample Data Example

In this example, we will import open geospatial data from the city of Zürich, Switzerland, into the PostGIS database we just created. We will then run a spatial query to find the number of public parking spots and handicap parking spots per district.

0. Prerequisite: This guide assumes you work on a system with GDAL CLI installed (`ogr2ogr` should be available). Alternatively, if you have [Docker](https://docs.docker.com/get-started/get-docker/) installed, you can run the commands below in an interactive GDAL docker container:
    ```bash
    docker run -it --rm ghcr.io/osgeo/gdal:ubuntu-small-latest bash
    ```

1. Specify parameters as environment variables in your terminal. We will reference these in the commands below.
   ```bash
   export MY_DROPLET_ID="your_droplet_ip_or_hostname"
   export MY_POSTGRES_ROLE="your_postgres_role"
   export MY_SECRET_POSTGRES_PASSWORD="your_secure_password"
   export MY_POSTGIS_DB="your_postgis_database"
   ```


2. Import the Zürich Stadtkreise dataset into PostGIS using ogr2ogr:
    ```bash
    ogr2ogr \
    -overwrite \
    -f "PostgreSQL" \
    -lco OVERWRITE=YES \
    -t_srs "EPSG:2056" \
    -nln zh_stadtkreise \
    -select kname \
    PG:"host=$MY_DROPLET_ID user=$MY_POSTGRES_ROLE dbname=$MY_POSTGIS_DB password=$MY_SECRET_POSTGRES_PASSWORD" \
    "WFS:https://www.ogd.stadt-zuerich.ch/wfs/geoportal/Stadtkreise?service=WFS&version=1.1.0&request=GetFeature&outputFormat=GeoJSON&typename=adm_stadtkreise_v"
    ```

3. Import the Zürich Public Parking dataset into PostGIS using ogr2ogr:
    ```bash
    ogr2ogr \
    -overwrite \
    -f "PostgreSQL" \
    -lco OVERWRITE=YES \
    -t_srs "EPSG:2056" \
    -nln zh_parkhaus \
    -select anzahl_oeffentliche_pp,behindertenparkplatz \
    PG:"host=$MY_DROPLET_ID user=$MY_POSTGRES_ROLE dbname=$MY_POSTGIS_DB password=$MY_SECRET_POSTGRES_PASSWORD" \
    "WFS:https://www.ogd.stadt-zuerich.ch/wfs/geoportal/Oeffentlich_zugaengliche_Parkhaeuser?service=WFS&version=1.1.0&request=GetFeature&outputFormat=GeoJSON&typename=poi_parkhaus_view"
    ```

4. Query Postgis database to return number of public parking spots and handicap parking spots per district (using `psql` or any other PostGIS-compatible client):
    ```sql
    SELECT sk.kname AS district,
        SUM(pp.anzahl_oeffentliche_pp) AS total_public_parking,
        SUM(pp.behindertenparkplatz) AS total_handicap_parking
    FROM zh_stadtkreise sk
    LEFT JOIN zh_parkhaus pp ON ST_Contains(sk.geometry, pp.geometry)
    GROUP BY sk.kname
    ORDER BY sk.kname;
    ``` 

    Or alternatively, run this query using ogr2ogr:
    ```bash
    ogr2ogr \
    -f "CSV" \
    /vsistdout/ \
    PG:"host=$MY_DROPLET_ID user=$MY_POSTGRES_ROLE dbname=$MY_POSTGIS_DB password=$MY_SECRET_POSTGRES_PASSWORD" \
    -sql "SELECT sk.kname AS district,
                SUM(pp.anzahl_oeffentliche_pp) AS total_public_parking,
                SUM(pp.behindertenparkplatz) AS total_handicap_parking
            FROM zh_stadtkreise sk
            LEFT JOIN zh_parkhaus pp ON ST_Contains(sk.geometry, pp.geometry)
            GROUP BY sk.kname
            ORDER BY sk.kname;"
    ``` 

