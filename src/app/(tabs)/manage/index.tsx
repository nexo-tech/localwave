import { TracksList } from "@/components/TracksList";
import { screenPadding } from "@/constants/tokens";
import { trackTitleFilter } from "@/helpers/filter";
import { generateTracksListId } from "@/helpers/miscellaneous";
import { useNavigationSearch } from "@/hooks/useNavigationSearch";
import { useFavorites } from "@/store/library";
import { defaultStyles } from "@/styles";
import * as FileSystem from "expo-file-system";
import { useMemo, useState } from "react";
import {
	Platform,
	ScrollView,
	Text,
	TouchableOpacity,
	View,
} from "react-native";
import {
	CloudStorage,
	CloudStorageError,
	CloudStorageProvider,
	useIsCloudAvailable,
} from "react-native-cloud-storage";
import DocumentPicker from "react-native-document-picker";
import * as mm from "music-metadata"

CloudStorage.setProvider(
	Platform.select({
		ios: CloudStorageProvider.ICloud,
		default: CloudStorageProvider.ICloud,
	}),
);


const ManageScreen = () => {
	const [d, setd] = useState("");
	const onSelectDirectory = async () => {
		try {
			const dir = await DocumentPicker.pickDirectory();
			if (dir?.uri) {
				const dirUri = dir.uri;
				setd(dirUri);
			} else {
				console.log("no uri");
			}
		} catch (error) {
			console.log(error);
		}
	};

	const runMyLogin = async () => {
		if (!d) {
			await onSelectDirectory()
		} else {
			try {
				console.log(d)
				// need globbing function to find all audio file uris
				const dir = await FileSystem.readDirectoryAsync(d)

				// then for each uri get metadata
				// and log it
				console.log(dir)
			} catch (e) {
				console.log(e)
			}
		}

	}
	const isCloudAvailable = useIsCloudAvailable();

	return (
		<View style={defaultStyles.container}>
			<View style={{ paddingTop: 150, width: "100%", flex: 1, height: "100%" }}>
				<View style={{ padding: 10 }}>
					<Text style={defaultStyles.text}>
						Cloud available: {isCloudAvailable ? "true" : "false"}
					</Text>
					<Text style={defaultStyles.text}>
						selected dir: {d ? d : "<not selected>"}
					</Text>
					<TouchableOpacity
						onPress={() => {
							runMyLogin();
						}}
						style={{ padding: 20 }}
					>
						<Text style={defaultStyles.text}>Run</Text>
					</TouchableOpacity>
				</View>
			</View>
		</View>
	);
};

export default ManageScreen;
