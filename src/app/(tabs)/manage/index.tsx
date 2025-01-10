import { useState } from "react";
import { Text, TouchableOpacity, View, Platform, ScrollView } from "react-native";
import DocumentPicker from "react-native-document-picker";
import * as FileSystem from "expo-file-system";
import MusicInfo from 'expo-music-info-2'
import {
	CloudStorage,
	CloudStorageProvider,
	useIsCloudAvailable,
} from "react-native-cloud-storage";
import { defaultStyles } from "@/styles";

CloudStorage.setProvider(
	Platform.select({
		ios: CloudStorageProvider.ICloud,
		default: CloudStorageProvider.ICloud,
	})
);

const audioExtensions = /\.(mp3|m4a|flac|wav|ogg|aac)$/i;

// Recursively find all audio files in a directory.
const getAudioFiles = async (dirUri: string): Promise<string[]> => {
	try {
		console.log("start...")
		const entries = await FileSystem.readDirectoryAsync(dirUri);
		console.log("entries", entries)
		let audioFiles = [];

		for (const entry of entries) {
			const entryUri = `${dirUri}/${encodeURIComponent(entry)}`;
			console.log("visiting", entryUri)
			const info = await FileSystem.getInfoAsync(entryUri);

			if (info.isDirectory) {
				// Recursively dive into subfolders
				console.log("visiting into", entryUri)
				const nested = await getAudioFiles(entryUri);
				audioFiles.push(...nested);
			} else {
				// If it ends with an audio extension, add to list
				if (audioExtensions.test(entry)) {
					audioFiles.push(entryUri);
				}
			}
		}
		return audioFiles as string[];
	} catch (e) {
		console.error(e)
		return []
	}
};

const ManageScreen = () => {
	const [directory, setDirectory] = useState("");
	const isCloudAvailable = useIsCloudAvailable();

	// Use DocumentPicker to select a directory.
	const onSelectDirectory = async () => {
		try {
			const dir = await DocumentPicker.pickDirectory();
			if (dir?.uri) setDirectory(dir.uri);
			else console.log("No directory selected");
		} catch (err) {
			console.log("Picker error:", err);
		}
	};

	// Read and log metadata for all audio files in selected directory.
	const runMyLogin = async () => {
		console.log("Y")
		if (!directory) {
			await onSelectDirectory();
			return;
		}
		console.log("handling audio files")
		try {
			console.log("visiting dir", directory)
			const audioFiles = await getAudioFiles(directory);
			console.log("Found audio files:", audioFiles);

			for (const fileUri of audioFiles) {
				try {
					const metadata = await MusicInfo.MusicInfo.getMusicInfoAsync(fileUri, {
						title: true,
						artist: true,
						album: true,
						genre: true,
						picture: true
					})
					console.log("Metadata for", fileUri, metadata);
				} catch (err) {
					console.log("Metadata parse error:", err);
				}
			}
		} catch (err) {
			console.log("Reading directory error:", err);
		}
	};
	console.log("heu")

	return (
		<View style={defaultStyles.container}>
			<View style={{ paddingTop: 150, width: "100%", flex: 1, height: "100%" }}>
				<View style={{ padding: 10 }}>
					<Text style={defaultStyles.text}>
						Cloud available: {isCloudAvailable ? "true" : "false"}
					</Text>
					<Text style={defaultStyles.text}>
						Selected dir: {directory || "<not selected>"}
					</Text>
					<TouchableOpacity onPress={runMyLogin} style={{ padding: 20 }}>
						<Text style={defaultStyles.text}>Run</Text>
					</TouchableOpacity>
				</View>
			</View>
		</View>
	);
};

export default ManageScreen;
