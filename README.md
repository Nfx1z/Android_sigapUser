# SIGAP User - Emergency Communication App

An Android application that enables users to send emergency messages via Bluetooth Low Energy (BLE) to field devices. Part of the SIGAP (Sistem Informasi Gawat Darurat - Emergency Information System) ecosystem for emergency communication.

## 📋 Overview

SIGAP User is a mobile-first emergency communication platform that uses **Bluetooth Low Energy (BLE)** as an alternative communication method when traditional networks are unavailable. The app combines BLE connectivity with GPS location data to deliver emergency messages to nearby field devices.

## 🏗️ System Architecture

SIGAP is a complete emergency communication system consisting of three main components:

### 1. **Android_sigapUser** (This Repository)
- End-user mobile application for emergency messaging
- Built with Flutter/Dart
- Uses BLE for message transmission
- Integrated GPS for location tracking
- Works as alternative communication when networks are down

### 2. **[sigapAdmin](https://github.com/Nfx1z/Android_sigapAdmin)**
- Administrative dashboard for government and emergency coordinators
- Manages emergency incidents and field operations
- Central coordination hub for emergency response
- User and field device management

### 3. **[Arduino Emergency Communication Code](https://github.com/Nfx1z/Arduino_emergencyComm_v2)**
- Field device firmware (Arduino/ESP32 based)
- Receives BLE messages from mobile app
- Processes and relays emergency alerts
- May include additional sensors and communication modules

## 🚀 Features

- **BLE Emergency Messaging**: Send messages directly to field devices via Bluetooth Low Energy
- **GPS Integration**: Automatic location capture with emergency messages
- **Offline Capability**: Works without internet connection (via BLE)
- **Location Sharing**: Share GPS coordinates with field devices
- **Message History**: View sent messages and responses
- **Device Discovery**: Find and connect to nearby field devices
- **Multi-category Support**: Fire, Medical, Police, Natural Disaster, etc.
- **Real-time Status**: Monitor message delivery status via BLE

## 📱 Technology Stack

- **Language**: Dart
- **Framework**: Flutter
- **Platform**: Android
- **Bluetooth**: BLE (Bluetooth Low Energy) communication
- **Location**: GPS/GNSS positioning
- **Architecture**: Clean Architecture with state management

## ⚙️ Prerequisites

- Flutter SDK (latest stable version)
- Dart SDK
- Android Studio or VS Code with Flutter extensions
- Android device or emulator (API level 21+, BLE support required)
- Compatible Arduino/ESP32 field device running SIGAP firmware

## 🔧 Installation

1. **Clone the repository**
   ```bash
   git clone https://github.com/Nfx1z/Android_sigapUser.git
   cd Android_sigapUser
