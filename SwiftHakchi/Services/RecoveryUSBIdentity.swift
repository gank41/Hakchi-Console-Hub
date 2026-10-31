import Foundation
import USBBridge

enum RecoveryUSBMode { case fel, rndis }
extension RecoveryProbeUSBDevice {
    /// Converts complete observations only; no absent field is a native wildcard.
    func nativeIdentity(for mode: RecoveryUSBMode) throws -> hakchi_usb_identity_t {
        guard let registryEntryID, registryEntryID > 0, locationID > 0 else {
            throw RecoveryProbeError.refused("The observed USB attachment has no complete registry identity. No device was opened.")
        }
        switch mode {
        case .fel: _ = try RecoveryProbePolicy.before([self])
        case .rndis:
            guard isRNDIS, deviceClass == 224 else {
                throw RecoveryProbeError.refused("The observed attachment is not recovery RNDIS. No device was opened.")
            }
        }
        return hakchi_usb_identity_t(registry_entry_id: registryEntryID, location_id: locationID,
            vendor_id: vendorID, product_id: productID, device_version: deviceVersion,
            device_class: deviceClass, require_empty_product: mode == .fel)
    }
}
