# Dynamic ETA Forecast for Coaching Trains

This repository contains the research, data analysis, technical documentation, and prototype planning for **SteamX**, a Smart India Hackathon 2026 solution for **Problem Statement 26028 – Dynamic Forecast of Expected Time of Arrival (ETA) for Coaching Trains**.

The repository includes documentation covering the complete proposed system, including:

* Historical Indian Railways datasets and their analysis
* Train schedules, delays, station information, and train details
* Data cleaning, preprocessing, and source reconciliation
* Live train-tracking data collection approach
* OpenStreetMap railway track and station geometry integration
* Master data joining and feature engineering
* Train precedence and crossing inference methodology
* Machine-learning based ETA prediction approach
* Model training and time-based validation strategy
* FastAPI backend and prediction API design
* React + Leaflet dashboard architecture
* Live journey replay and what-if prediction concepts
* Continuous feedback and model retraining pipeline
* Production transition plan for CRIS/ISRO RTIS integration

The repository also contains detailed **data-flow and technical-flow documentation** describing how information moves from raw data sources through preprocessing, feature engineering, prediction, API serving, and the frontend dashboard.

The project is designed as a prototype architecture that can eventually replace public/scraped train-tracking sources with official **CRIS/ISRO RTIS** data without requiring major changes to the downstream prediction system.
